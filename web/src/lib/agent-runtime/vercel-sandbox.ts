import crypto from "node:crypto";
import { Sandbox, Snapshot } from "@vercel/sandbox";
import ms from "ms";
import { getBaseSnapshotId, recordBaseSnapshot } from "../base-snapshots";
import { shouldExposeAnthropicKeyToTerminal } from "./config";
import {
	type ComputeProvider,
	type ComputeProviderAvailability,
	type ComputeProviderDescriptor,
	type SandboxRequest,
	type SandboxResult,
	type SandboxState,
	type SnapshotCapable,
	type StreamChunk,
	type TerminalCapable,
	buildEnrichedMessage,
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
 * v1:         node22 + @anthropic-ai/claude-code
 * v2-ttyd:    + ttyd for WebSocket terminal access
 * v3-tmux:    + tmux (broken — see v3-tmux-c for the debug arc)
 * v3-tmux-b:  attempted libs copy (also broken)
 * v3-tmux-c:  assertRunCommand exitCode check — finally surfaced the
 *               real error: "apt-get: command not found". The Vercel
 *               sandbox node22 runtime doesn't have apt at all.
 * v3-tmux-d:  static tmux binary from mjakob-gh/build-static-tmux —
 *               the version that actually works.
 * v4-welcome: + Spaces welcome banner in /etc/bash.bashrc — didn't
 *               fire because tmux starts bash as a login shell which
 *               sources /etc/profile.d/*.sh, not /etc/bash.bashrc.
 * v4-welcome-b: + welcome banner installed at
 *                 /etc/profile.d/spaces-welcome.sh so login shells
 *                 fire it. Same guard env var means it only fires
 *                 once per session. Banner worked but showed
 *                 "fairchild/workspaces.git" because the sed regex
 *                 couldn't strip the `.git` suffix.
 * v4-welcome-c: + banner uses bash parameter expansion instead of
 *                 sed so the `.git` suffix is stripped correctly
 *                 and the owner/repo extraction is readable.
 * v5-pi-skills:  + pi coding agent (@mariozechner/pi-coding-agent),
 *                  skills CLI, mise, uv, and pre-installed Anthropic
 *                  skills from anthropics/skills and
 *                  anthropics/claude-plugins-official.
 *                  Discovery: dnf IS available (Amazon Linux 2023)
 *                  for system packages — use `sudo: true`.
 */
const BASE_SNAPSHOT_VERSION = "v5-pi-skills";

/**
 * Static tmux binary download URL. See
 * https://github.com/mjakob-gh/build-static-tmux for the build
 * sources. The `.stripped` variant is smaller (~500KB) and
 * statically-linked against musl, ncurses, and libevent so it has no
 * runtime dependencies.
 *
 * If this URL ever breaks, the pythops/tmux-linux-binary project is
 * a known-good alternative.
 */
const TMUX_STATIC_URL =
	"https://github.com/mjakob-gh/build-static-tmux/releases/latest/download/tmux.linux-amd64.stripped.gz";
const PROVIDER_ID = "vercel-sandbox";
const SANDBOX_REPO_DIR = "/vercel/sandbox/repo";
const GIT_CREDENTIAL_TOKEN_PATH = "/vercel/sandbox/github-clone-token";
const GIT_CREDENTIAL_HELPER_PATH =
	"/vercel/sandbox/github-credential-helper.sh";
const DEV_TTYD_TOKEN_SECRET = "dev-only-fallback-do-not-use-in-prod";

/**
 * Run a command in a sandbox and throw if it exits non-zero. The
 * Vercel sandbox SDK's `runCommand` returns a `CommandFinished` with
 * an `exitCode` property but does NOT throw on non-zero exit — the
 * caller has to check explicitly.
 *
 * We used to ignore the exit code in `resolveBaseSnapshot`, which
 * meant a failing apt-get would silently proceed and we'd snapshot
 * a half-installed state (the v3-tmux / v3-tmux-b outage). Any
 * multi-step install script should go through this helper.
 */
async function assertRunCommand(
	sandbox: Sandbox,
	label: string,
	params: Parameters<Sandbox["runCommand"]>[0],
): Promise<void> {
	// Overload pick: the object form returns CommandFinished.
	const cmd = (await sandbox.runCommand(
		params as Parameters<Sandbox["runCommand"]>[0] & object,
		// biome-ignore lint/suspicious/noExplicitAny: SDK has two overloads, tsc narrows the wrong one
	)) as any;
	if (cmd.exitCode !== 0) {
		let stderr = "";
		try {
			stderr = await cmd.output("both");
		} catch {
			// best effort
		}
		throw new Error(
			`[vercel-sandbox] ${label} exited ${cmd.exitCode}\n${stderr.slice(0, 2000)}`,
		);
	}
}

function buildGitCredentialHelperFiles(
	authToken: string,
): Array<{ path: string; content: Buffer }> {
	return [
		{
			path: GIT_CREDENTIAL_TOKEN_PATH,
			content: Buffer.from(stripQuotes(authToken)),
		},
		{
			path: GIT_CREDENTIAL_HELPER_PATH,
			content: Buffer.from(`#!/bin/sh
case "$1" in
  get)
    echo username=x-access-token
    printf 'password='
    cat ${GIT_CREDENTIAL_TOKEN_PATH}
    printf '\\n'
    ;;
esac
`),
		},
	];
}

export function buildGitCloneArgs(params: {
	cloneUrl: string;
	authToken?: string;
	branch?: string;
}): string[] {
	const cloneArgs: string[] = [];
	if (params.authToken) {
		cloneArgs.push("-c", `credential.helper=${GIT_CREDENTIAL_HELPER_PATH}`);
	}
	cloneArgs.push("clone", "--depth", "1");
	if (params.branch) {
		cloneArgs.push("--branch", params.branch);
	}
	cloneArgs.push(params.cloneUrl, SANDBOX_REPO_DIR);
	return cloneArgs;
}

async function prepareGitCloneAuth(
	sandbox: Sandbox,
	authToken: string | undefined,
	label: string,
): Promise<void> {
	if (!authToken) return;
	await sandbox.writeFiles(buildGitCredentialHelperFiles(authToken));
	await assertRunCommand(sandbox, `chmod git token (${label})`, {
		cmd: "chmod",
		args: ["600", GIT_CREDENTIAL_TOKEN_PATH],
	});
	await assertRunCommand(sandbox, `chmod git credential helper (${label})`, {
		cmd: "chmod",
		args: ["700", GIT_CREDENTIAL_HELPER_PATH],
	});
}

async function cleanupGitCloneAuth(
	sandbox: Sandbox,
	label: string,
): Promise<void> {
	await assertRunCommand(sandbox, `remove git clone credentials (${label})`, {
		cmd: "rm",
		args: ["-f", GIT_CREDENTIAL_TOKEN_PATH, GIT_CREDENTIAL_HELPER_PATH],
	});
}

async function scrubGitOrigin(
	sandbox: Sandbox,
	cloneUrl: string,
	label: string,
): Promise<void> {
	await assertRunCommand(sandbox, `scrub git origin (${label})`, {
		cmd: "git",
		args: ["-C", SANDBOX_REPO_DIR, "remote", "set-url", "origin", cloneUrl],
	});
}

function stripQuotes(s: string): string {
	return s.replace(/^["']|["']$/g, "");
}

export function terminalAnthropicApiKey(
	env: Partial<NodeJS.ProcessEnv> = process.env,
): string | null {
	if (!shouldExposeAnthropicKeyToTerminal(env)) return null;
	const apiKey = env.ANTHROPIC_API_KEY;
	return apiKey ? stripQuotes(apiKey) : null;
}

function configuredTtydTokenSecret(): string | null {
	return (
		process.env.TTYD_TOKEN_SECRET ?? process.env.BETTER_AUTH_SECRET ?? null
	);
}

function resolveTtydTokenSecret(): string {
	const secret = configuredTtydTokenSecret();
	if (secret) return secret;
	if (process.env.NODE_ENV !== "production") return DEV_TTYD_TOKEN_SECRET;
	throw new Error(
		"TTYD_TOKEN_SECRET or BETTER_AUTH_SECRET is required for terminal access in production",
	);
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

	// 2. Create fresh base: node22 + agents + tools + skills
	const sandbox = await Sandbox.create({
		...getCredentials(),
		runtime: "node22",
		resources: { vcpus: 2 },
		timeout: ms("15m"),
	});

	await assertRunCommand(sandbox, "npm install claude-code", {
		cmd: "npm",
		args: ["install", "-g", "@anthropic-ai/claude-code"],
		sudo: true,
	});

	await assertRunCommand(sandbox, "npm install pi-coding-agent", {
		cmd: "npm",
		args: ["install", "-g", "@mariozechner/pi-coding-agent"],
		sudo: true,
	});

	await assertRunCommand(sandbox, "npm install skills", {
		cmd: "npm",
		args: ["install", "-g", "skills"],
		sudo: true,
	});

	// Install mise and uv as static binaries into /usr/local/bin.
	// mise: runtime/env manager (https://mise.jdx.dev)
	// uv: fast Python package manager (https://docs.astral.sh/uv)
	await assertRunCommand(sandbox, "install mise + uv static", {
		cmd: "bash",
		args: [
			"-c",
			[
				"set -euo pipefail",
				"MISE_VERSION='v2026.5.5'",
				"MISE_SHA256='3aaab5c05a8a94a93b42b4f581779bbd5c44ddb251e7f3639fc671ec5c6aab8a'",
				'MISE_URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-x64"',
				"echo '--- downloading mise ---'",
				'curl -fsSL "$MISE_URL" -o /tmp/mise',
				"printf '%s  %s\\n' \"$MISE_SHA256\" /tmp/mise | sha256sum -c -",
				"install -m 0755 /tmp/mise /usr/local/bin/mise",
				"rm -f /tmp/mise",
				"echo '--- mise version ---'",
				"/usr/local/bin/mise --version",
				"echo '--- downloading uv ---'",
				"curl -fsSL https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz | tar xz -C /tmp",
				"mv /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv",
				"mv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx",
				"chmod +x /usr/local/bin/uv /usr/local/bin/uvx",
				"rm -rf /tmp/uv-x86_64-unknown-linux-gnu",
				"echo '--- uv version ---'",
				"/usr/local/bin/uv --version",
				"echo '--- install complete ---'",
			].join(" && "),
		],
		sudo: true,
	});

	// Pre-install Anthropic skill packs so they're baked into every
	// sandbox. The skills CLI clones from GitHub and writes SKILL.md
	// files into the agent's skill directory. Runs during snapshot
	// creation (full internet access) so per-session sandboxes don't
	// need npm registry or GitHub access for skills discovery.
	await assertRunCommand(sandbox, "install anthropics/skills", {
		cmd: "skills",
		args: ["add", "anthropics/skills", "-y"],
	});

	await assertRunCommand(
		sandbox,
		"install anthropics/claude-plugins-official",
		{
			cmd: "skills",
			args: ["add", "anthropics/claude-plugins-official", "-y"],
		},
	);

	// Install ttyd + tmux as static binaries into /usr/local/bin.
	// The Vercel sandbox node22 runtime is Amazon Linux 2023 — it has
	// dnf (NOT apt-get). For system packages use:
	//   await assertRunCommand(sandbox, "install foo", {
	//     cmd: "dnf", args: ["install", "-y", "foo"], sudo: true,
	//   });
	// See: https://vercel.com/kb/guide/how-to-install-system-packages-in-vercel-sandbox
	// We use static binaries here since ttyd and tmux aren't in the
	// Amazon Linux repos and the static builds have zero runtime deps.
	await assertRunCommand(sandbox, "install ttyd + tmux static", {
		cmd: "bash",
		args: [
			"-c",
			[
				"set -euo pipefail",
				"echo '--- downloading ttyd ---'",
				"curl -sfL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd",
				"chmod +x /usr/local/bin/ttyd",
				"echo '--- ttyd version ---'",
				"/usr/local/bin/ttyd --version",
				"echo '--- downloading tmux static ---'",
				`curl -sfL ${TMUX_STATIC_URL} -o /tmp/tmux.gz`,
				"gunzip -f /tmp/tmux.gz",
				"mv /tmp/tmux /usr/local/bin/tmux",
				"chmod +x /usr/local/bin/tmux",
				"echo '--- tmux version ---'",
				"/usr/local/bin/tmux -V",
				"echo '--- install complete ---'",
			].join(" && "),
		],
		sudo: true,
	});

	// Install the Spaces welcome banner. Goes in /etc/profile.d/ so
	// it fires on login shells (which is what tmux starts by
	// default) — v4-welcome put it only in /etc/bash.bashrc which
	// covers non-login interactive shells, and that's the wrong
	// path for tmux → bash.
	//
	// The snippet guards via $__SPACES_WELCOMED so child shells and
	// subsequent tmux windows skip the banner. Reads the repo name
	// at runtime from git remote so the content adapts per sandbox.
	//
	// Heredoc is single-quoted so every $VAR is sandbox-side, not
	// interpolated on the host.
	await assertRunCommand(sandbox, "install welcome banner", {
		cmd: "bash",
		args: [
			"-c",
			`cat > /etc/profile.d/spaces-welcome.sh <<'__SPACES_WELCOME_EOF__'
# Spaces welcome banner — added by base snapshot install.
# Shown once per shell session via the __SPACES_WELCOMED guard.
if [ -z "\${__SPACES_WELCOMED:-}" ] && [ -t 1 ]; then
  export __SPACES_WELCOMED=1
  __spaces_repo=""
  if [ -d /vercel/sandbox/repo/.git ]; then
    __spaces_url=$(cd /vercel/sandbox/repo && git remote get-url origin 2>/dev/null)
    if [ -n "\$__spaces_url" ]; then
      __spaces_url="\${__spaces_url%.git}"            # strip trailing .git
      __spaces_name="\${__spaces_url##*/}"            # repo name = basename
      __spaces_dir="\${__spaces_url%/*}"              # dirname of url
      __spaces_owner="\${__spaces_dir##*[/:]}"        # owner = last segment of dirname
      __spaces_repo="\${__spaces_owner}/\${__spaces_name}"
      unset __spaces_url __spaces_name __spaces_dir __spaces_owner
    fi
  fi
  printf '\\n'
  printf '\\033[1;36m━━━ Spaces sandbox ━━━\\033[0m\\n'
  printf '\\033[0;36m repo   \\033[0m %s\\n' "\${__spaces_repo:-(no repo)}"
  printf '\\033[0;36m cwd    \\033[0m %s\\n' "$(pwd)"
  printf '\\033[0;36m tmux   \\033[0m session "shell"  (Ctrl-B d to detach)\\n'
  printf '\\033[0;36m timeout\\033[0m 30 min idle\\n'
  printf '\\033[0;90m ──────────────────────\\033[0m\\n'
  printf '\\n'
  unset __spaces_repo
fi
__SPACES_WELCOME_EOF__
chmod 0644 /etc/profile.d/spaces-welcome.sh
# Verify the file is there at install time (surfaces errors early).
test -s /etc/profile.d/spaces-welcome.sh`,
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

export class VercelSandboxProvider
	implements ComputeProvider, SnapshotCapable, TerminalCapable
{
	readonly descriptor: ComputeProviderDescriptor = {
		id: "vercel-sandbox",
		displayName: "Vercel Sandbox",
		maxSessionDuration: ms("5h"),
		supportsSnapshot: true,
		supportsStreaming: true,
		terminalMode: "pty",
	};

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		// Vercel Sandbox uses OIDC token on Vercel, or explicit token locally
		const hasOidc = !!process.env.VERCEL_OIDC_TOKEN;
		const hasToken =
			!!process.env.VERCEL_TOKEN &&
			!!process.env.VERCEL_TEAM_ID &&
			!!process.env.VERCEL_PROJECT_ID;

		if (!hasOidc && !hasToken) {
			return {
				available: false,
				reason:
					"Missing Vercel credentials (VERCEL_OIDC_TOKEN or VERCEL_TOKEN + VERCEL_TEAM_ID + VERCEL_PROJECT_ID)",
			};
		}

		if (!configuredTtydTokenSecret() && process.env.NODE_ENV === "production") {
			return {
				available: false,
				reason:
					"Missing TTYD_TOKEN_SECRET or BETTER_AUTH_SECRET (required for terminal URL authentication)",
			};
		}

		return { available: true };
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
			await assertRunCommand(sandbox, "git clone (agent sandbox)", {
				cmd: "git",
				args: cloneArgs,
			});

			const instanceId = sandbox.sandboxId;
			const tools =
				request.tools === "conversational" ? CONVERSATIONAL_TOOLS : FULL_TOOLS;

			const fullMessage = buildEnrichedMessage(
				request.message,
				request.contextMessages,
			);

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
			await assertRunCommand(sandbox, "chmod api-key-helper (agent sandbox)", {
				cmd: "chmod",
				args: ["+x", `${CLAUDE_CONFIG_DIR}/api-key-helper.sh`],
			});

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

	async stopSandbox(instanceId: string): Promise<void> {
		// Fast path: in-memory (same process that created the sandbox)
		const local = activeSandboxes.get(instanceId);
		if (local) {
			await local.stop();
			activeSandboxes.delete(instanceId);
			return;
		}
		// Cross-instance path: Sandbox.get() works across serverless boundaries
		const sandbox = await Sandbox.get({
			sandboxId: instanceId,
			...getCredentials(),
		});
		await sandbox.stop();
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
			await assertRunCommand(sandbox, "chmod api-key-helper (restore)", {
				cmd: "chmod",
				args: ["+x", `${CLAUDE_CONFIG_DIR}/api-key-helper.sh`],
			});
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
		authToken?: string;
		branch?: string;
	}): Promise<SandboxResult> {
		const baseSnapshotId = await getOrCreateBaseSnapshot();
		const terminalApiKey = terminalAnthropicApiKey();

		const sandbox = await Sandbox.create({
			...getCredentials(),
			source: { type: "snapshot", snapshotId: baseSnapshotId },
			timeout: ms("30m"),
			resources: { vcpus: 2 },
			ports: [7681],
			env: terminalApiKey
				? {
						ANTHROPIC_API_KEY: terminalApiKey,
						CLAUDE_CONFIG_DIR,
					}
				: undefined,
			networkPolicy: { allow: ALLOWED_DOMAINS },
		});

		try {
			await prepareGitCloneAuth(sandbox, params.authToken, "terminal sandbox");

			// Clone the target repo with a token-free URL. If auth is needed,
			// Git uses a temporary credential helper that is removed below.
			const cloneArgs = buildGitCloneArgs(params);
			await assertRunCommand(sandbox, "git clone (terminal sandbox)", {
				cmd: "git",
				args: cloneArgs,
			});
			await scrubGitOrigin(sandbox, params.cloneUrl, "terminal sandbox");
			await cleanupGitCloneAuth(sandbox, "terminal sandbox");

			// User-facing terminal shells do not receive the host Anthropic key
			// unless explicitly opted in. Agent chat keeps its separate auth path.
			if (terminalApiKey) {
				await sandbox.writeFiles(claudeAuthFiles(terminalApiKey));
				await assertRunCommand(
					sandbox,
					"chmod api-key-helper (terminal sandbox)",
					{
						cmd: "chmod",
						args: ["+x", `${CLAUDE_CONFIG_DIR}/api-key-helper.sh`],
					},
				);
			}

			await startTtyd(sandbox);

			const instanceId = sandbox.sandboxId;
			activeSandboxes.set(instanceId, sandbox);
			return { instanceId, status: "ready" };
		} catch (err) {
			await cleanupGitCloneAuth(sandbox, "terminal sandbox").catch(() => {});
			await sandbox.stop().catch(() => {});
			throw err;
		}
	}

	async resolveSandboxState(instanceId: string): Promise<SandboxState> {
		return resolveSandboxState(instanceId);
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
export type { SandboxState } from "./types";

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
 * The terminal URL `https://sb-xxx.vercel.run/<token>/ws` is the final ttyd
 * gate after the app's authenticated one-time ticket exchange. By making the
 * path a 24-char HMAC of the sandbox ID + a server-side secret, an attacker
 * who guesses a sandbox ID still can't connect without knowing the secret.
 *
 * The token is stateless — anywhere we know the sandbox ID, we can
 * recompute it. No DB column needed.
 *
 * Exported for testing.
 */
export function ttydPathToken(sandboxId: string): string {
	const secret = resolveTtydTokenSecret();
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

function sandboxTerminalState(
	sandbox: Sandbox,
	instanceId: string,
): SandboxState {
	let domain: string;
	try {
		domain = sandbox.domain(7681);
	} catch {
		// Pre-v2 sandbox without port 7681 published. We have no way to
		// connect a terminal to it, so treat it as dead for our purposes.
		return { alive: false };
	}
	return {
		alive: true,
		terminalUrl: ttydUrl(domain, instanceId),
	};
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

	// Ensure the tmux socket directory exists before ttyd launches tmux.
	// After snapshot restore `/tmp` may be empty, and the static tmux
	// binary sometimes fails to create `/tmp/tmux-<uid>/` on its own
	// (produces: "tmux socket dir: `/tmp/tmux-0` does not exist"). We
	// also remove any stale socket files left over from a previous tmux
	// server that was running when the snapshot was taken — a dead socket
	// prevents `new-session -A` from starting a fresh server.
	await sandbox.runCommand({
		cmd: "bash",
		args: [
			"-c",
			"rm -rf /tmp/tmux-* && mkdir -p /tmp/tmux-0 && chmod 700 /tmp/tmux-0",
		],
		sudo: true,
	});

	// tmux is a static binary in /usr/local/bin/tmux — no library
	// path setup needed. ttyd execs tmux directly.
	await sandbox.runCommand({
		cmd: "ttyd",
		args: [
			"-W",
			"-p",
			"7681",
			"-b",
			`/${token}`,
			"/usr/local/bin/tmux",
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
		return sandboxTerminalState(cached, instanceId);
	}

	// Cross-instance path: single HTTP call to Vercel API
	let sandbox: Sandbox;
	try {
		sandbox = await Sandbox.get({
			sandboxId: instanceId,
			...getCredentials(),
		});
	} catch {
		// Sandbox record doesn't exist at all (never created, or purged)
		return { alive: false };
	}
	if (!ALIVE_STATUSES.has(sandbox.status)) {
		return { alive: false };
	}
	return sandboxTerminalState(sandbox, instanceId);
}
