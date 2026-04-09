import crypto from "node:crypto";
import { Sandbox, Snapshot } from "@vercel/sandbox";
import ms from "ms";
import { getBaseSnapshotId, recordBaseSnapshot } from "../base-snapshots";
import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	SnapshotCapable,
	StreamChunk,
} from "./types";

const CONVERSATIONAL_TOOLS = "Read,Glob,Grep,WebFetch";
const FULL_TOOLS = "Read,Write,Edit,Bash,Glob,Grep,WebFetch";

/**
 * Where the sandbox stores claude CLI settings + credentials. We override
 * the default `~/.claude` location so we don't depend on whatever HOME
 * happens to be inside the sandbox. The CLI honors `$CLAUDE_CONFIG_DIR`
 * for both settings.json lookup and credential storage.
 */
const CLAUDE_CONFIG_DIR = "/vercel/sandbox/claude-config";

/**
 * Bump this version when the base snapshot contents change (new tools,
 * package updates, etc.). Old versions remain valid until manually deleted —
 * this lets us roll back without rebuilding.
 *
 * v1:       node22 + @anthropic-ai/claude-code
 * v2-ttyd:  + ttyd for WebSocket terminal access
 * v3-tmux:  + tmux so the shell process survives snapshot/restore
 *             (ttyd now runs `tmux new-session -A -s shell` instead of
 *             bare bash — see `startTtyd` below)
 */
const BASE_SNAPSHOT_VERSION = "v3-tmux";
const PROVIDER_ID = "vercel-sandbox";

function stripQuotes(s: string): string {
	return s.replace(/^["']|["']$/g, "");
}

/**
 * Parse a single line of stream-json output from `claude -p --output-format stream-json --verbose`.
 *
 * Event types:
 *   stream_event  — raw API deltas; we extract text_delta for streaming text
 *                   and content_block_start for tool_use notifications
 *   result        — final result (ignored; we already streamed the text)
 *   system        — init/status events (ignored)
 */
export function parseStreamJsonLine(line: string): StreamChunk | null {
	if (!line.trim()) return null;

	let event: Record<string, unknown>;
	try {
		event = JSON.parse(line);
	} catch {
		// Non-JSON output (e.g., bash error before claude starts)
		return line.trim() ? { type: "text", content: line } : null;
	}

	if (event.type === "stream_event") {
		const inner = event.event as Record<string, unknown> | undefined;
		if (!inner) return null;

		// Text delta — the main streaming content
		const delta = inner.delta as Record<string, unknown> | undefined;
		if (delta?.type === "text_delta" && typeof delta.text === "string") {
			return { type: "text", content: delta.text };
		}

		// Tool use start — surface as a status message
		if (inner.type === "content_block_start") {
			const block = inner.content_block as Record<string, unknown> | undefined;
			if (block?.type === "tool_use" && typeof block.name === "string") {
				return {
					type: "tool_use",
					content: block.name,
					metadata: { tool: block.name },
				};
			}
		}
	}

	return null;
}

/** Credentials passed to every Sandbox.create() and Snapshot.list() call. */
function getCredentials(): {
	token?: string;
	teamId?: string;
	projectId?: string;
} {
	return {
		token: process.env.VERCEL_TOKEN,
		teamId: process.env.VERCEL_TEAM_ID,
		projectId: process.env.VERCEL_PROJECT_ID,
	};
}

const ALLOWED_DOMAINS = [
	"api.anthropic.com",
	"github.com",
	"*.githubusercontent.com",
];

/** Promise-memoized to prevent duplicate snapshot creation on concurrent requests. */
let _baseSnapshotPromise: Promise<string> | undefined;

function getOrCreateBaseSnapshot(): Promise<string> {
	if (!_baseSnapshotPromise) {
		_baseSnapshotPromise = resolveBaseSnapshot().catch((err) => {
			_baseSnapshotPromise = undefined; // Allow retry on failure
			throw err;
		});
	}
	return _baseSnapshotPromise;
}

async function resolveBaseSnapshot(): Promise<string> {
	// 1. Check our DB for a snapshot ID matching the current version
	const recorded = await getBaseSnapshotId(PROVIDER_ID, BASE_SNAPSHOT_VERSION);
	if (recorded) {
		// Verify it still exists in Vercel (could have been deleted/expired)
		const list = await Snapshot.list(getCredentials());
		const found = list.json.snapshots.find(
			(s: { id: string; status: string }) =>
				s.id === recorded && s.status === "created",
		);
		if (found) return recorded;
		// Recorded snapshot is gone — fall through to recreate
	}

	// 2. Create fresh base: node22 + Claude Code CLI + ttyd + tmux
	const sandbox = await Sandbox.create({
		...getCredentials(),
		runtime: "node22",
		resources: { vcpus: 2 },
		timeout: ms("10m"),
	});

	await sandbox.runCommand({
		cmd: "npm",
		args: ["install", "-g", "@anthropic-ai/claude-code"],
		sudo: true,
	});

	// Install ttyd for WebSocket terminal access + tmux for session
	// continuity across snapshot/restore. The ttyd binary comes from the
	// project's GitHub releases; tmux comes from the distro package
	// manager. Vercel sandbox's node22 runtime is Debian-based, so apt
	// is available.
	await sandbox.runCommand({
		cmd: "bash",
		args: [
			"-c",
			"curl -sL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd && apt-get update && apt-get install -y --no-install-recommends tmux && tmux -V",
		],
		sudo: true,
	});

	const snapshot = await sandbox.snapshot({ expiration: ms("30d") });

	// 3. Record the new snapshot so future requests find it
	await recordBaseSnapshot(
		PROVIDER_ID,
		BASE_SNAPSHOT_VERSION,
		snapshot.snapshotId,
	);

	return snapshot.snapshotId;
}

/** Active sandbox instances keyed by instanceId (sandboxId). */
const activeSandboxes = new Map<string, Sandbox>();

export class VercelSandboxProvider implements ComputeProvider, SnapshotCapable {
	readonly descriptor: ComputeProviderDescriptor = {
		id: "vercel-sandbox",
		displayName: "Vercel Sandbox",
		maxSessionDuration: ms("5h"),
		supportsSnapshot: true,
		supportsStreaming: true,
	};

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		// Vercel Sandbox uses OIDC token on Vercel, or explicit token locally
		const hasOidc = !!process.env.VERCEL_OIDC_TOKEN;
		const hasToken =
			!!process.env.VERCEL_TOKEN &&
			!!process.env.VERCEL_TEAM_ID &&
			!!process.env.VERCEL_PROJECT_ID;

		if (hasOidc || hasToken) {
			return { available: true };
		}
		return {
			available: false,
			reason:
				"Missing Vercel credentials (VERCEL_OIDC_TOKEN or VERCEL_TOKEN + VERCEL_TEAM_ID + VERCEL_PROJECT_ID)",
		};
	}

	async createSandbox(request: SandboxRequest): Promise<SandboxResult> {
		const apiKey = process.env.ANTHROPIC_API_KEY;
		if (!apiKey) {
			throw new Error(
				"ANTHROPIC_API_KEY is required for agent sandbox sessions",
			);
		}

		const baseSnapshotId = await getOrCreateBaseSnapshot();

		const sandbox = await Sandbox.create({
			...getCredentials(),
			source: { type: "snapshot", snapshotId: baseSnapshotId },
			timeout: request.readOnly ? ms("10m") : ms("30m"),
			resources: { vcpus: 2 },
			ports: [7681],
			env: {
				ANTHROPIC_API_KEY: stripQuotes(apiKey),
				CLAUDE_CONFIG_DIR,
				...request.envVars,
			},
			networkPolicy: { allow: ALLOWED_DOMAINS },
		});

		try {
			// Clone the target repo (use token for private repos)
			const cloneArgs = ["clone", "--depth", "1"];
			if (request.branch) {
				cloneArgs.push("--branch", request.branch);
			}
			cloneArgs.push(request.cloneUrl, "/vercel/sandbox/repo");
			await sandbox.runCommand("git", cloneArgs);

			const instanceId = sandbox.sandboxId;
			const tools =
				request.tools === "conversational" ? CONVERSATIONAL_TOOLS : FULL_TOOLS;

			// Build the message with conversation context prepended
			let fullMessage = request.message;
			if (request.contextMessages?.length) {
				const contextBlock = request.contextMessages
					.map(
						(m) =>
							`[${m.timestamp}] ${m.author} (${m.authorType}): ${m.content}`,
					)
					.join("\n\n");
				fullMessage = `## Recent conversation context\n\n${contextBlock}\n\n---\n\n## Current message\n\n${request.message}`;
			}

			const filesToWrite: Array<{
				path: string;
				content: Buffer;
			}> = [
				{
					path: "/vercel/sandbox/system-prompt.txt",
					content: Buffer.from(request.systemPrompt),
				},
				{
					path: "/vercel/sandbox/message.txt",
					content: Buffer.from(fullMessage),
				},
				{
					path: "/vercel/sandbox/run-agent.sh",
					content: Buffer.from(buildRunnerScript(tools)),
				},
				{
					path: "/vercel/sandbox/env.sh",
					content: Buffer.from(buildEnvSource(apiKey)),
				},
				...claudeAuthFiles(apiKey),
			];

			if (request.chatHistory) {
				filesToWrite.push({
					path: "/vercel/sandbox/chat-history.txt",
					content: Buffer.from(request.chatHistory),
				});
			}

			if (request.claudeSessionId) {
				filesToWrite.push({
					path: "/vercel/sandbox/claude-session-id.txt",
					content: Buffer.from(request.claudeSessionId),
				});
			}

			await sandbox.writeFiles(filesToWrite);
			// claude CLI invokes apiKeyHelper as an executable, so the helper
			// script needs +x. writeFiles doesn't take a mode arg.
			await sandbox.runCommand("chmod", [
				"+x",
				`${CLAUDE_CONFIG_DIR}/api-key-helper.sh`,
			]);

			// Auth-gated ttyd on port 7681 — same path token as the terminal
			// tab so an attacker who finds an agent sandbox URL still can't
			// shell into it without knowing the token secret.
			await startTtyd(sandbox);

			activeSandboxes.set(instanceId, sandbox);
			return { instanceId, status: "ready" };
		} catch (err) {
			await sandbox.stop().catch(() => {});
			throw err;
		}
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) {
			yield { type: "error", content: "Sandbox not found" };
			return;
		}

		// Run in detached mode so we can stream stdout incrementally via logs()
		const cmd = await sandbox.runCommand({
			cmd: "bash",
			args: ["/vercel/sandbox/run-agent.sh"],
			cwd: "/vercel/sandbox/repo",
			detached: true,
		});

		let hasOutput = false;
		for await (const log of cmd.logs()) {
			if (log.stream === "stdout" && log.data) {
				hasOutput = true;
				yield { type: "text", content: log.data };
			}
		}

		const finished = await cmd.wait();
		if (finished.exitCode !== 0 && !hasOutput) {
			const stderr = await finished.stderr();
			yield {
				type: "error",
				content:
					stderr.trim() || `Claude exited with code ${finished.exitCode}`,
			};
			return;
		}

		yield { type: "done", content: "" };
	}

	async sendMessage(
		instanceId: string,
		message: string,
		context?: { chatHistory?: string; claudeSessionId?: string },
	): Promise<void> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) throw new Error(`Sandbox ${instanceId} not found`);

		const files: Array<{ path: string; content: Buffer }> = [
			{
				path: "/vercel/sandbox/message.txt",
				content: Buffer.from(message),
			},
		];
		if (context?.chatHistory) {
			files.push({
				path: "/vercel/sandbox/chat-history.txt",
				content: Buffer.from(context.chatHistory),
			});
		}
		if (context?.claudeSessionId) {
			// Signal the runner script to use --resume instead of --session-id
			files.push({
				path: "/vercel/sandbox/claude-resume.flag",
				content: Buffer.from("1"),
			});
		}
		await sandbox.writeFiles(files);
	}

	async destroySandbox(instanceId: string): Promise<void> {
		const sandbox = activeSandboxes.get(instanceId);
		if (sandbox) {
			await sandbox.stop();
			activeSandboxes.delete(instanceId);
		}
	}

	async createSnapshot(instanceId: string): Promise<string> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) throw new Error(`Sandbox ${instanceId} not found`);

		const snapshot = await sandbox.snapshot({
			expiration: ms("7d"),
		});
		await sandbox.stop();
		activeSandboxes.delete(instanceId);
		return snapshot.snapshotId;
	}

	async restoreSnapshot(snapshotId: string): Promise<SandboxResult> {
		const sandbox = await Sandbox.create({
			...getCredentials(),
			source: { type: "snapshot", snapshotId },
			timeout: ms("10m"),
			resources: { vcpus: 2 },
			ports: [7681],
			env: {
				ANTHROPIC_API_KEY: stripQuotes(process.env.ANTHROPIC_API_KEY ?? ""),
				CLAUDE_CONFIG_DIR,
			},
			networkPolicy: { allow: ALLOWED_DOMAINS },
		});

		// The snapshot was taken from a sandbox built by createSandbox, so
		// the auth files already exist on disk. Re-write them anyway in
		// case the snapshot pre-dates the auth fix or someone deleted them.
		const restoreApiKey = stripQuotes(process.env.ANTHROPIC_API_KEY ?? "");
		if (restoreApiKey) {
			await sandbox.writeFiles(claudeAuthFiles(restoreApiKey));
			await sandbox.runCommand("chmod", [
				"+x",
				`${CLAUDE_CONFIG_DIR}/api-key-helper.sh`,
			]);
		}

		// Restart ttyd with the auth-gated base-path. The token is derived
		// from the new sandbox ID, not the old one — ttydUrl() also reads
		// from the new ID, so they stay in sync.
		await startTtyd(sandbox);

		const instanceId = sandbox.sandboxId;
		activeSandboxes.set(instanceId, sandbox);
		return { instanceId, status: "ready" };
	}

	/**
	 * Create a standalone terminal sandbox — no agent runner, just a shell
	 * with the repo cloned and ttyd running on port 7681.
	 *
	 * Unlike `createSandbox()`, this is NOT tied to an agent chat flow. The
	 * sandbox stays alive for the full timeout (30 minutes) so users can
	 * interact with it via the terminal tab directly.
	 */
	async createTerminalSandbox(params: {
		cloneUrl: string;
		branch?: string;
	}): Promise<SandboxResult> {
		const baseSnapshotId = await getOrCreateBaseSnapshot();
		const apiKey = process.env.ANTHROPIC_API_KEY;

		const sandbox = await Sandbox.create({
			...getCredentials(),
			source: { type: "snapshot", snapshotId: baseSnapshotId },
			timeout: ms("30m"),
			resources: { vcpus: 2 },
			ports: [7681],
			// Pass ANTHROPIC_API_KEY + CLAUDE_CONFIG_DIR so a user who runs
			// `claude` from the terminal shell isn't greeted with "Not
			// logged in". The terminal is auth-gated by ttydPathToken, so
			// only the authenticated user can read these env vars.
			env: apiKey
				? {
						ANTHROPIC_API_KEY: stripQuotes(apiKey),
						CLAUDE_CONFIG_DIR,
					}
				: undefined,
			networkPolicy: { allow: ALLOWED_DOMAINS },
		});

		try {
			// Clone the target repo
			const cloneArgs = ["clone", "--depth", "1"];
			if (params.branch) {
				cloneArgs.push("--branch", params.branch);
			}
			cloneArgs.push(params.cloneUrl, "/vercel/sandbox/repo");
			await sandbox.runCommand("git", cloneArgs);

			// Same claude auth setup as the agent path so `claude` works
			// out of the box from the shell.
			if (apiKey) {
				await sandbox.writeFiles(claudeAuthFiles(apiKey));
				await sandbox.runCommand("chmod", [
					"+x",
					`${CLAUDE_CONFIG_DIR}/api-key-helper.sh`,
				]);
			}

			await startTtyd(sandbox);

			const instanceId = sandbox.sandboxId;
			activeSandboxes.set(instanceId, sandbox);
			return { instanceId, status: "ready" };
		} catch (err) {
			await sandbox.stop().catch(() => {});
			throw err;
		}
	}
}

/**
 * Liveness + terminal URL for a sandbox, in a single Vercel API call.
 *
 * Returns `{ alive: false }` if the sandbox is gone (timed out, stopped,
 * or never existed). Returns `{ alive: true, terminalUrl? }` if the
 * sandbox exists — `terminalUrl` is present when port 7681 is published
 * (v2-ttyd snapshot), absent for older v1 sandboxes that lack ttyd.
 *
 * Uses `Sandbox.get()` so it works across serverless function boundaries:
 * the in-memory `activeSandboxes` map is only populated in whichever
 * function instance created the sandbox, but the status API runs in
 * separate instances. The map is a fast-path cache.
 */
export type SandboxState =
	| { alive: false }
	| { alive: true; terminalUrl?: string };

/**
 * Vercel sandbox statuses that mean "this sandbox can accept commands".
 *
 * `Sandbox.get()` returns successfully for stopped/failed sandboxes too —
 * it fetches the metadata record, not the runtime state. We have to
 * explicitly check the status field to distinguish alive from dead.
 */
const ALIVE_STATUSES: ReadonlySet<string> = new Set(["running", "pending"]);

/**
 * Derive a stable per-sandbox path token used as ttyd's `--base-path`.
 *
 * The terminal URL `https://sb-xxx.vercel.run/<token>/ws` is the only
 * gate between an attacker and shell access. By making the path a 24-char
 * HMAC of the sandbox ID + a server-side secret, an attacker who guesses
 * a sandbox ID still can't connect without knowing the secret.
 *
 * The token is stateless — anywhere we know the sandbox ID, we can
 * recompute it. No DB column needed.
 *
 * Exported for testing.
 */
export function ttydPathToken(sandboxId: string): string {
	const secret =
		process.env.TTYD_TOKEN_SECRET ??
		process.env.BETTER_AUTH_SECRET ??
		"dev-only-fallback-do-not-use-in-prod";
	return crypto
		.createHmac("sha256", secret)
		.update(sandboxId)
		.digest("hex")
		.slice(0, 24);
}

/**
 * Build the ttyd WebSocket URL for a sandbox: append the auth token path
 * + `/ws`. ttyd serves its WebSocket at `<base-path>/ws`.
 */
function ttydUrl(domain: string, sandboxId: string): string {
	const token = ttydPathToken(sandboxId);
	return `${domain.replace(/\/$/, "")}/${token}/ws`;
}

/**
 * Start ttyd inside a sandbox with the auth-gated base-path. This is the
 * ONE place that decides ttyd's invocation — every sandbox we create
 * (agent chat, terminal tab, restored snapshot) must call this so the
 * URL we later construct via `ttydUrl()` matches what ttyd actually
 * serves and the shell stays behind the HMAC token.
 *
 * ttyd runs `tmux new-session -A -s shell` instead of bare bash so the
 * shell process survives snapshot/restore:
 *
 *   -A   attach to the named session if it already exists (post-restore),
 *        otherwise create a new one (first launch).
 *   -s shell   name the session so Resume can re-attach explicitly.
 *
 * Without tmux, Resume restores the filesystem snapshot but bash is a
 * fresh process — `cd somewhere`, `export VAR=...`, command history, and
 * any in-flight processes are gone. With tmux, the user lands in the
 * exact shell state they left when they resume a paused sandbox.
 */
async function startTtyd(sandbox: Sandbox): Promise<void> {
	const token = ttydPathToken(sandbox.sandboxId);
	await sandbox.runCommand({
		cmd: "ttyd",
		args: [
			"-W",
			"-p",
			"7681",
			"-b",
			`/${token}`,
			"tmux",
			"new-session",
			"-A",
			"-s",
			"shell",
		],
		cwd: "/vercel/sandbox/repo",
		detached: true,
	});
}

/**
 * Build the agent runner script. The script reads prompt + message + an
 * optional claude session id from files in /vercel/sandbox/, and pipes
 * the message into `claude -p`. Reading from files (not env or
 * positional args) keeps shell injection out of the picture.
 *
 * The first thing the script does is `source /vercel/sandbox/env.sh`,
 * which the caller writes alongside the runner. Diagnostic probe
 * (#308) revealed that env vars passed via `Sandbox.create({env: ...})`
 * are NOT inherited by `sandbox.runCommand()` invocations — every
 * runCommand spawns with an empty env relative to the sandbox config.
 * Sourcing an env file is the most reliable way to get
 * ANTHROPIC_API_KEY and CLAUDE_CONFIG_DIR into the runner's
 * environment.
 *
 * On first run, --session-id creates a named claude session that
 * persists to disk. On restore (claude-resume.flag exists), --resume
 * loads the prior session, giving the agent full memory of its previous
 * reasoning and tool calls.
 *
 * One source of truth for how the agent runs — anyone touching the
 * runner edits this function.
 */
function buildRunnerScript(tools: string): string {
	return `#!/bin/bash
set -e
source /vercel/sandbox/env.sh
PROMPT=$(cat /vercel/sandbox/system-prompt.txt)
SESSION_ARGS=""
if [ -f /vercel/sandbox/claude-resume.flag ]; then
  SESSION_ARGS="--resume $(cat /vercel/sandbox/claude-session-id.txt)"
elif [ -f /vercel/sandbox/claude-session-id.txt ]; then
  SESSION_ARGS="--session-id $(cat /vercel/sandbox/claude-session-id.txt)"
fi
cat /vercel/sandbox/message.txt | claude -p $SESSION_ARGS --system-prompt "$PROMPT" --allowedTools ${tools}
`;
}

/**
 * Build the env-source file. Sandbox.create({env}) doesn't propagate
 * to runCommand subprocesses (verified via #308 diagnostic probe), so
 * we write a sourceable shell file with the values inlined and the
 * runner sources it before invoking claude.
 *
 * Single-quoted to avoid shell interpretation of the API key value.
 */
function buildEnvSource(apiKey: string): string {
	return `# Sourced by /vercel/sandbox/run-agent.sh — see buildEnvSource() comment.
export ANTHROPIC_API_KEY='${stripQuotes(apiKey).replace(/'/g, "'\\''")}'
export CLAUDE_CONFIG_DIR='${CLAUDE_CONFIG_DIR}'
`;
}

/**
 * Files needed for claude CLI to authenticate non-interactively. The
 * documented mechanism is `apiKeyHelper`, a shell command in
 * `settings.json` whose stdout is the API key.
 *
 * #306 used `echo $ANTHROPIC_API_KEY` as the helper command, but
 * production verification showed the agent still hitting "Not logged
 * in". The CLI invokes the helper via execve, not via /bin/sh, so
 * `$ANTHROPIC_API_KEY` was passed literally rather than expanded.
 *
 * Fix: write a real shell script that prints the key from a
 * single-quoted heredoc — no env var dependency, no quoting puzzles
 * with the key value. The settings.json points apiKeyHelper at the
 * absolute path of this script.
 *
 * We also point CLAUDE_CONFIG_DIR at this directory in the sandbox env
 * so the CLI looks here instead of $HOME/.claude (which we'd otherwise
 * have to guess at — root vs vercel-sandbox).
 *
 * https://code.claude.com/docs/en/authentication
 */
function claudeAuthFiles(
	apiKey: string,
): Array<{ path: string; content: Buffer }> {
	const helperPath = `${CLAUDE_CONFIG_DIR}/api-key-helper.sh`;
	const settings = JSON.stringify({ apiKeyHelper: helperPath }, null, 2);
	// Single-quoted heredoc avoids any escaping problems with the key.
	const helper = `#!/bin/sh
cat <<'__CLAUDE_KEY_EOF__'
${stripQuotes(apiKey)}
__CLAUDE_KEY_EOF__
`;
	return [
		{
			path: `${CLAUDE_CONFIG_DIR}/settings.json`,
			content: Buffer.from(settings),
		},
		{
			path: helperPath,
			content: Buffer.from(helper),
		},
	];
}

export async function resolveSandboxState(
	instanceId: string,
): Promise<SandboxState> {
	// Fast path: in-memory map (same serverless instance)
	const cached = activeSandboxes.get(instanceId);
	if (cached && ALIVE_STATUSES.has(cached.status)) {
		try {
			return {
				alive: true,
				terminalUrl: ttydUrl(cached.domain(7681), instanceId),
			};
		} catch {
			// Pre-v2 sandbox without port 7681 published. We have no way to
			// connect a terminal to it, so treat it as dead for our purposes —
			// reconciliation will mark the session completed and the user can
			// start a fresh sandbox that has ttyd.
			return { alive: false };
		}
	}

	// Cross-instance path: single HTTP call to Vercel API
	try {
		const sandbox = await Sandbox.get({
			sandboxId: instanceId,
			...getCredentials(),
		});
		if (!ALIVE_STATUSES.has(sandbox.status)) {
			return { alive: false };
		}
		try {
			return {
				alive: true,
				terminalUrl: ttydUrl(sandbox.domain(7681), instanceId),
			};
		} catch {
			return { alive: false };
		}
	} catch {
		// Sandbox record doesn't exist at all (never created, or purged)
		return { alive: false };
	}
}
