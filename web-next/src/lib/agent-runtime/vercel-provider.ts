/*
 * The real compute provider: runs one Claude Code turn inside a Vercel sandbox
 * via @ai-sdk/harness and streams its parts back as StreamChunks. The sandbox is
 * created through the harness factory so its bootstrap installs the `claude` CLI
 * (and reuses a snapshot template across turns); a per-session `onSession` hook
 * injects the GitHub App installation token as a git credential — the token
 * rides in via the command `env`, never the transcript — and clones the target
 * repo into a persistent per-session workspace, so the agent can edit, push, and
 * open a PR against it. The turn is driven by the user's actual message.
 *
 * Sessions are durable: after each turn the harness session is `detach()`-ed
 * (parked with the sandbox left running) and its resume payload persisted; the
 * next turn reconnects that warm session so the conversation and working copy
 * continue. Reconnect is bounded by the sandbox lifetime — once it expires the
 * turn falls back to a fresh clone. Heavy deps load lazily so the seam stays
 * light for the mock path; sessions opt in via sessions.provider = "vercel".
 */
import type { HarnessAgentSandboxConfig } from "@ai-sdk/harness/agent";
import { mintInstallationToken } from "../diag/github-app";
import type {
	ComputeProvider,
	SessionResumeHandle,
	TurnRequest,
} from "./provider";
import type { StreamChunk } from "./stream-chunk";

// Type-only imports of the lazily-loaded factories keep the seam light (no
// eager harness load) while giving the shared builders real signatures.
type CreateClaudeCode =
	typeof import("@ai-sdk/harness-claude-code")["createClaudeCode"];
type CreateVercelSandbox =
	typeof import("@ai-sdk/sandbox-vercel")["createVercelSandbox"];

/** Repo the agent clones into its workspace and opens its PR against. */
const TARGET_REPO = process.env.AGENT_TARGET_REPO ?? "fairchild/workspaces";
/** Port the in-sandbox harness bridge binds; must be declared on the sandbox. */
const BRIDGE_PORT = 4000;
/**
 * Max sandbox lifetime. Also the resume window: a parked (detached) session
 * reconnects only while its sandbox is still alive, so this bounds how long a
 * conversation can idle between turns before the next turn re-clones fresh.
 */
const SANDBOX_TIMEOUT_MS = 30 * 60 * 1000;
/** The persistent per-session working copy: name under the sandbox default cwd. */
const WORKSPACE_DIR_NAME = "workspace";
/** Absolute path to that working copy (sandbox default cwd is /vercel/sandbox). */
const WORKSPACE_DIR = `/vercel/sandbox/${WORKSPACE_DIR_NAME}`;
/**
 * Stable template name so `runTurn` and `prewarmVercelTemplate` target the same
 * named snapshot; the harness reuses a template only when the sandbox identity
 * matches, and the name is part of that identity.
 */
const TEMPLATE_NAME = "web-next-claude-code";
/**
 * Bump whenever the `onBootstrap` side effects change — it invalidates the
 * reusable snapshot so the next prewarm (or first turn) rebuilds the template.
 */
const BOOTSTRAP_HASH = "claude-code-cli-v1";

/** A stable per-session branch the agent commits and opens its PR from. */
function sessionBranch(sessionId: string): string {
	return `agent/session-${sessionId.slice(0, 8)}`;
}

/**
 * The per-session setup script, run on every turn (fresh and resumed). It
 * configures git identity + a credential store from $GH_TOKEN (passed via the
 * command environment, never interpolated), drops the token at /tmp/gh_token for
 * the PR API, then clones the target repo into the persistent workspace and
 * creates the session branch — all idempotent, so a resumed sandbox with the
 * clone already present is a no-op and a fresh fallback sandbox re-clones.
 */
function buildSessionSetupScript(sessionId: string): string {
	const branch = sessionBranch(sessionId);
	return [
		"set -e",
		"umask 077",
		'printf "https://x-access-token:%s@github.com\\n" "$GH_TOKEN" > "$HOME/.git-credentials"',
		"git config --global credential.helper store",
		"git config --global user.name 'web-next agent'",
		"git config --global user.email 'agent@users.noreply.github.com'",
		'printf "%s" "$GH_TOKEN" > /tmp/gh_token',
		`if [ ! -d ${WORKSPACE_DIR}/.git ]; then`,
		`  git clone --depth 50 https://github.com/${TARGET_REPO}.git ${WORKSPACE_DIR}`,
		`  git -C ${WORKSPACE_DIR} checkout -b ${branch}`,
		"fi",
		"",
	].join("\n");
}

function asText(value: unknown): string {
	if (typeof value === "string") return value;
	try {
		return JSON.stringify(value);
	} catch {
		return String(value);
	}
}

/**
 * A human-readable string for an error value. `JSON.stringify(new Error(...))`
 * is `"{}"` — message/stack are non-enumerable — so error parts must be read
 * for their `.message` (and common nested `.cause`/`.error`) before falling
 * back to a plain string, or the transcript shows an empty `{}`.
 */
export function errorText(value: unknown): string {
	if (value == null) return "unknown error";
	if (typeof value === "string") return value;
	if (value instanceof Error) return value.message || value.name;
	if (typeof value === "object") {
		const o = value as { message?: unknown; error?: unknown; cause?: unknown };
		if (typeof o.message === "string" && o.message) return o.message;
		if (o.error != null && o.error !== value) return errorText(o.error);
		if (o.cause != null && o.cause !== value) return errorText(o.cause);
		const json = asText(value);
		if (json && json !== "{}") return json;
	}
	return String(value);
}

/**
 * Canonicalizes the harness's lowercase tool names (`write`, `bash`, `edit`) to
 * the Capitalized form the Folio ledger and turn-stats key on (`Write`, `Bash`,
 * `Edit`) — so the real provider's tool cards, verbs, and file/diff stats match
 * what the mock provider and UI were built against.
 */
export function canonicalToolName(name: unknown): string {
	const raw = typeof name === "string" ? name : asText(name);
	return raw.length === 0 ? raw : raw[0].toUpperCase() + raw.slice(1);
}

/**
 * Renders a tool result to display text. Bash-style results arrive as
 * `{ exitCode, stdout, stderr }`; surface stdout/stderr (what the ledger and the
 * "N passed" test-detection read) rather than the raw JSON. String results
 * (Edit/Write success messages) pass through.
 */
export function toolResultContent(output: unknown): string {
	if (output && typeof output === "object" && "stdout" in output) {
		const o = output as { stdout?: string; stderr?: string; exitCode?: number };
		const text = [o.stdout, o.stderr].filter(Boolean).join("\n").trim();
		if (text.length > 0) return text;
		return o.exitCode && o.exitCode !== 0 ? `exited ${o.exitCode}` : "";
	}
	return asText(output);
}

/**
 * Maps the AI SDK `fullStream` parts a harness turn produces onto the runtime's
 * StreamChunk protocol. Structural parts (text/reasoning start-end, steps,
 * tool-input deltas, raw) are dropped — the chunk adapter derives that framing
 * from the deltas itself. A single terminal `done` closes the turn.
 */
export async function* mapFullStream(
	fullStream: AsyncIterable<{ type: string; [k: string]: unknown }>,
	startedAt: number,
): AsyncGenerator<StreamChunk> {
	let outputTokens: number | undefined;
	for await (const part of fullStream) {
		if (process.env.HARNESS_DEBUG === "1") {
			const detail =
				part.type === "error" || part.type === "tool-error"
					? errorText(part.error)
					: JSON.stringify(part).slice(0, 240);
			console.error(`[dbg part] ${part.type} ${detail}`);
		}
		switch (part.type) {
			case "text-delta":
				if (part.text) yield { type: "text", content: part.text as string };
				break;
			case "reasoning-delta":
				if (part.text)
					yield { type: "reasoning", content: part.text as string };
				break;
			case "tool-call": {
				const toolName = canonicalToolName(part.toolName);
				yield {
					type: "tool_use",
					content: toolName,
					metadata: {
						toolUseId: part.toolCallId,
						toolName,
						input: part.input,
					},
				};
				break;
			}
			case "tool-result": {
				const content = toolResultContent(part.output);
				yield {
					type: "tool_result",
					content,
					metadata: { toolUseId: part.toolCallId, output: content },
				};
				break;
			}
			case "tool-error":
				yield {
					type: "tool_result",
					content: errorText(part.error),
					metadata: { toolUseId: part.toolCallId, isError: true },
				};
				break;
			case "error":
				yield { type: "error", content: errorText(part.error) };
				break;
			case "abort":
				yield {
					type: "error",
					content: `aborted${part.reason ? `: ${errorText(part.reason)}` : ""}`,
				};
				break;
			case "finish": {
				const usage = part.totalUsage as { outputTokens?: number } | undefined;
				outputTokens = usage?.outputTokens;
				break;
			}
			default:
				break; // structural parts — the adapter reconstructs framing
		}
	}
	yield {
		type: "done",
		content: "",
		metadata: { durationMs: Date.now() - startedAt, tokenCount: outputTokens },
	};
}

/**
 * The turn prompt. It drives the agent with the user's actual message against
 * the persistent workspace clone. A fresh session gets a one-time preamble
 * establishing where the working copy lives and how to open a PR; a resumed
 * session already carries that context in its harness conversation, so it
 * receives the user's message alone.
 */
function buildPrompt(
	userMessage: string,
	sessionId: string,
	firstTurn: boolean,
): string {
	if (!firstTurn) return userMessage;
	const branch = sessionBranch(sessionId);
	return [
		`You are working inside a persistent clone of the GitHub repository ${TARGET_REPO}. The current directory (${WORKSPACE_DIR}) is the repo root, checked out on branch \`${branch}\`. This workspace and our conversation persist across turns — later messages continue in the same working copy.`,
		``,
		`Working notes:`,
		`- Relative paths and git commands resolve against the repo (you are inside it) — edit and \`git status\`/\`git diff\` normally.`,
		`- To open or update a pull request: commit, \`git push -u origin HEAD\`, then call the GitHub API with the token in /tmp/gh_token, e.g. \`curl -sS -X POST -H "Authorization: Bearer $(cat /tmp/gh_token)" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${TARGET_REPO}/pulls -d '{"title":"…","head":"${branch}","base":"main","body":"…"}'\`. Report the \`html_url\`.`,
		`- Only open a PR when the request calls for one; otherwise just do the work and summarize it.`,
		``,
		`The user's request:`,
		userMessage,
	].join("\n");
}

/**
 * The model credential, anthropic-preferred. The claude CLI consumes
 * ANTHROPIC_API_KEY natively (the most reliable in-sandbox path); the AI Gateway
 * key is the fallback. Part of the template identity, so both `runTurn` and the
 * prewarm path resolve it through this one function.
 */
function resolveAuth() {
	const anthropicKey = process.env.ANTHROPIC_API_KEY;
	const gatewayKey = process.env.AI_GATEWAY_API_KEY;
	return anthropicKey
		? { anthropic: { apiKey: anthropicKey } }
		: gatewayKey
			? { gateway: { apiKey: gatewayKey } }
			: undefined;
}

/** The claude-code harness adapter. Identical inputs on both paths. */
function createHarness(
	createClaudeCode: CreateClaudeCode,
	auth: ReturnType<typeof resolveAuth>,
) {
	return createClaudeCode({ auth, thinking: "on" });
}

/** The Vercel sandbox naming scheme the adapter uses for per-session sandboxes. */
const SESSION_SANDBOX_PREFIX = "ai-sdk-harness-session";

/**
 * The Vercel sandbox provider, built via the factory path with a stable `name`
 * so `runTurn` and prewarm target the same named template snapshot.
 *
 * Resume shim: the adapter's `resumeSession` calls `Sandbox.get({ name })`
 * without the token/teamId/projectId it was configured with, so it relies on
 * ambient credentials — the auto-injected OIDC token in prod (works), but
 * nothing locally, where the reconnect 404s. When we hold explicit credentials
 * we override `resumeSession` to `Sandbox.get` with them, then re-wrap the raw
 * sandbox through the adapter's own wrap path so resume works in both places.
 */
function createSandboxProvider(createVercelSandbox: CreateVercelSandbox) {
	const token = process.env.VERCEL_TOKEN;
	const teamId = process.env.VERCEL_TEAM_ID;
	const projectId = process.env.VERCEL_PROJECT_ID;
	const provider = createVercelSandbox({
		runtime: "node22",
		ports: [BRIDGE_PORT],
		resources: { vcpus: 4 },
		timeout: SANDBOX_TIMEOUT_MS,
		token,
		teamId,
		projectId,
		name: TEMPLATE_NAME,
	});
	if (!(token && teamId && projectId)) return provider;
	// The provider's methods are bound instance fields, so a spread preserves
	// them; only resumeSession is replaced with the credential-forwarding form.
	return {
		...provider,
		resumeSession: async ({
			sessionId,
			abortSignal,
		}: {
			sessionId: string;
			abortSignal?: AbortSignal;
		}) => {
			const { Sandbox } = await import("@vercel/sandbox");
			const sandbox = await Sandbox.get({
				name: `${SESSION_SANDBOX_PREFIX}-${sessionId}`,
				token,
				teamId,
				projectId,
				...(abortSignal ? { signal: abortSignal } : {}),
			});
			return createVercelSandbox({ sandbox }).createSession();
		},
	};
}

/**
 * The bootstrap baked into the reusable snapshot: install the claude CLI so the
 * bridge finds it on PATH. This is the template-identity-affecting config shared
 * by `runTurn` and prewarm — no `onSession` here, since the per-turn credential
 * injection is not part of the snapshot and must not enter the template identity.
 */
const SANDBOX_BOOTSTRAP: Omit<HarnessAgentSandboxConfig, "onSession"> = {
	// Bake the claude CLI into the reusable snapshot so the bridge finds it on
	// PATH; a verifiable install beats relying on the adapter's implicit
	// first-start install (which was leaving `claude` missing).
	bootstrapHash: BOOTSTRAP_HASH,
	onBootstrap: async ({ session }) => {
		const r = await session.run({
			command:
				"command -v claude >/dev/null 2>&1 || npm install -g @anthropic-ai/claude-code",
		});
		if (r.exitCode !== 0)
			throw new Error(
				`claude CLI install failed (exit ${r.exitCode}): ${r.stderr.slice(0, 400)}`,
			);
		if (process.env.HARNESS_DEBUG === "1") {
			const v = await session.run({ command: "claude --version" });
			console.error(`[dbg onBootstrap] claude installed: ${v.stdout.trim()}`);
		}
	},
};

/**
 * Build (or refresh) the sandbox template out of band so the first user turn
 * resumes from a snapshot instead of paying the ~1–4 min claude-CLI install
 * inside its own request budget. Idempotent — a fast no-op once the snapshot
 * exists. MUST build the harness adapter, sandbox provider, and bootstrap config
 * through the same shared builders `runTurn` uses, or it warms a template the
 * turn never reuses.
 */
export async function prewarmVercelTemplate(): Promise<{ tookMs: number }> {
	const started = Date.now();
	const [{ prepareHarnessSandboxTemplate }, { createClaudeCode }, { createVercelSandbox }] =
		await Promise.all([
			import("@ai-sdk/harness/agent"),
			import("@ai-sdk/harness-claude-code"),
			import("@ai-sdk/sandbox-vercel"),
		]);
	await prepareHarnessSandboxTemplate({
		harness: createHarness(createClaudeCode, resolveAuth()),
		sandboxProvider: createSandboxProvider(createVercelSandbox),
		sandboxConfig: SANDBOX_BOOTSTRAP,
	});
	return { tookMs: Date.now() - started };
}

export const vercelProvider: ComputeProvider = {
	id: "vercel",
	async *runTurn(request: TurnRequest): AsyncIterable<StreamChunk> {
		const startedAt = Date.now();

		yield { type: "status", content: "Minting GitHub credential" };
		const { token } = await mintInstallationToken(TARGET_REPO);

		yield { type: "status", content: "Preparing sandbox runtime" };
		const [{ HarnessAgent }, { createClaudeCode }, { createVercelSandbox }] =
			await Promise.all([
				import("@ai-sdk/harness/agent"),
				import("@ai-sdk/harness-claude-code"),
				import("@ai-sdk/sandbox-vercel"),
			]);

		const debugHarness = process.env.HARNESS_DEBUG === "1";

		// The sandbox session is captured here so the turn can run `git diff` after
		// streaming to synthesize diff cards (the harness session drives turns, not
		// arbitrary commands). The sandbox stays alive until detach, so it is valid
		// through the end of the turn.
		let sandbox: RunnableSandbox | undefined;

		const agent = new HarnessAgent({
			id: `web-next-${request.sessionId}`,
			harness: createHarness(createClaudeCode, resolveAuth()),
			sandbox: createSandboxProvider(createVercelSandbox),
			sandboxConfig: {
				// Same template-identity bootstrap as prewarm, plus the per-session
				// credential hook (which is deliberately excluded from the snapshot).
				...SANDBOX_BOOTSTRAP,
				// Run the agent inside the cloned workspace so its relative paths and
				// git commands resolve against the repo — without this the CLI's cwd
				// is a scratch dir and edits land outside the clone. Relative to the
				// sandbox default (/vercel/sandbox), so this is WORKSPACE_DIR.
				workDir: WORKSPACE_DIR_NAME,
				onSession: async ({ session }) => {
					sandbox = session as RunnableSandbox;
					await session.writeTextFile({
						path: "/tmp/session-setup.sh",
						content: buildSessionSetupScript(request.sessionId),
					});
					const res = await session.run({
						command: "bash /tmp/session-setup.sh",
						env: { GH_TOKEN: token },
					});
					if (res.exitCode !== 0)
						throw new Error(
							`session setup failed (exit ${res.exitCode}): ${res.stderr.slice(0, 300)}`,
						);
					if (debugHarness) {
						const chk = await session.run({
							command: `which claude; git -C ${WORKSPACE_DIR} rev-parse --abbrev-ref HEAD 2>&1`,
						});
						console.error(
							`[dbg onSession] setup ok; ${chk.stdout.trim().replace(/\n/g, " | ")}`,
						);
					}
				},
			},
			...(debugHarness
				? {
						debug: { enabled: true, level: "debug" as const },
						onLog: (e: { level: string; subsystem: string; message: string }) =>
							console.error(`[harness ${e.level}] ${e.subsystem}: ${e.message}`),
					}
				: {}),
		});

		// The stable id that names the sandbox: reuse the parked session's id on
		// resume (so `Sandbox.get` finds the running sandbox), else the web-next
		// session id. On a fresh boot that collides with a lingering sandbox, fall
		// back to a unique id so the turn still runs.
		let sandboxSessionId = request.resume?.harnessSessionId ?? request.sessionId;

		// Reconnect the parked session when its sandbox is still alive; otherwise
		// boot fresh. A resumed session keeps the conversation and working copy, so
		// buildPrompt then sends the user's message alone.
		let session: Awaited<ReturnType<typeof agent.createSession>> | undefined;
		let resumed = false;
		if (request.resume) {
			yield { type: "status", content: "Resuming session" };
			try {
				session = await agent.createSession({
					sessionId: request.resume.harnessSessionId,
					resumeFrom: JSON.parse(request.resume.resumeState),
				});
				resumed = true;
			} catch (error) {
				if (debugHarness)
					console.error(`[dbg resume failed] ${asText((error as Error)?.message)}`);
				yield {
					type: "status",
					content: "Previous sandbox expired — starting fresh",
				};
			}
		}
		if (!session) {
			yield { type: "status", content: "Booting Claude Code in sandbox" };
			sandboxSessionId = request.sessionId;
			try {
				session = await agent.createSession({ sessionId: sandboxSessionId });
			} catch (error) {
				// A parked sandbox under this name may still be alive (resume failed
				// for another reason); a same-name create is rejected. Boot under a
				// fresh unique name so the turn proceeds — the next turn resumes it.
				if (!isNameCollision(error)) throw error;
				sandboxSessionId = `${request.sessionId}-${Date.now().toString(36)}`;
				session = await agent.createSession({ sessionId: sandboxSessionId });
			}
		}

		let detached = false;
		try {
			const result = await agent.stream({
				session,
				prompt: buildPrompt(request.userMessage, request.sessionId, !resumed),
			});
			let doneChunk: StreamChunk | undefined;
			for await (const chunk of mapFullStream(
				result.fullStream as AsyncIterable<{ type: string; [k: string]: unknown }>,
				startedAt,
			)) {
				if (chunk.type === "done") {
					doneChunk = chunk;
					break; // the terminal chunk — emit diff cards, then park, then it
				}
				yield chunk;
			}
			// Synthesize a diff card per changed file from the working tree (the
			// Edit/Write results carry no patch; the real diff lives in git). Emit
			// each as a tool_use + tool_result pair — the Folio adapter renders the
			// DiffCard from a tool_result's metadata.diff, and the AI SDK only keeps
			// a tool result that has a matching opened call.
			for (const diff of await changedFileDiffs(sandbox)) {
				const toolUseId = `diff:${diff.file}`;
				yield {
					type: "tool_use",
					content: "Diff",
					metadata: {
						toolUseId,
						toolName: "Diff",
						input: { file_path: diff.file },
					},
				};
				yield {
					type: "tool_result",
					content: "",
					metadata: { toolUseId, output: "", diff },
				};
			}
			// Park the session so the next turn reconnects it; carry the resume
			// payload out on the done chunk for the ingest loop to persist. If
			// parking fails, `resume: null` clears the stale handle and the session
			// is torn down below.
			const resume = await parkSession(session, sandboxSessionId, debugHarness);
			detached = resume !== null;
			yield {
				...(doneChunk ?? { type: "done", content: "" }),
				metadata: { ...doneChunk?.metadata, resume },
			};
		} finally {
			if (!detached) await session.destroy().catch(() => {});
		}
	},
};

/**
 * Whether a sandbox-create error is a name collision (a parked sandbox under the
 * same name is still alive). The Vercel APIError's `message` is only the status
 * line ("Status code 400 …"); the reason lives in its `json`/`text`, so match
 * across all of them.
 */
function isNameCollision(error: unknown): boolean {
	const e = error as { message?: unknown; text?: unknown; json?: unknown };
	const haystack = [asText(e?.message), asText(e?.text), asText(e?.json)].join(" ");
	return /already exists/i.test(haystack);
}

/** A sandbox session that can run shell commands (the onSession surface). */
interface RunnableSandbox {
	run: (opts: {
		command: string;
	}) => PromiseLike<{ exitCode: number; stdout: string; stderr: string }>;
}

/** A rendered diff card: file, line counts, and the hunk lines. */
interface DiffCard {
	file: string;
	additions: number;
	deletions: number;
	note: string;
	lines: { kind: "add" | "del" | "context"; text: string }[];
}

/** Beyond this many hunk lines a single file's card is truncated. */
const DIFF_LINE_CAP = 200;

/**
 * Runs `git diff` over the workspace (untracked files marked intent-to-add so
 * new files show) and parses it into one diff card per changed file. Best-effort
 * — any failure yields no cards, never breaking the turn.
 */
async function changedFileDiffs(sandbox: RunnableSandbox | undefined): Promise<DiffCard[]> {
	if (!sandbox) return [];
	try {
		const res = await sandbox.run({
			command: `git -C ${WORKSPACE_DIR} add -N . >/dev/null 2>&1; git -C ${WORKSPACE_DIR} diff`,
		});
		return parseGitDiff(res.stdout);
	} catch {
		return [];
	}
}

/** Splits a multi-file unified diff into per-file cards. */
export function parseGitDiff(raw: string): DiffCard[] {
	const cards: DiffCard[] = [];
	let current: DiffCard | undefined;
	let inHunk = false;
	for (const line of raw.split("\n")) {
		if (line.startsWith("diff --git")) {
			if (current && current.lines.length > 0) cards.push(current);
			const file = line.match(/ b\/(.+)$/)?.[1] ?? "(file)";
			current = { file, additions: 0, deletions: 0, note: "edit landed", lines: [] };
			inHunk = false;
			continue;
		}
		if (!current) continue;
		if (line.startsWith("@@")) {
			inHunk = true;
			continue;
		}
		if (!inHunk || line.startsWith("+++") || line.startsWith("---")) continue;
		if (line.startsWith("\\")) continue; // "\ No newline at end of file"
		if (current.lines.length >= DIFF_LINE_CAP) continue;
		if (line.startsWith("+")) {
			current.additions += 1;
			current.lines.push({ kind: "add", text: line });
		} else if (line.startsWith("-")) {
			current.deletions += 1;
			current.lines.push({ kind: "del", text: line });
		} else if (line.startsWith(" ")) {
			current.lines.push({ kind: "context", text: line });
		}
	}
	if (current && current.lines.length > 0) cards.push(current);
	return cards;
}

/**
 * Detaches the session (parks it with the sandbox left running) under the id
 * that names its sandbox, and returns the handle to persist for the next turn —
 * or null when parking fails, so the caller tears the session down and clears
 * any stored handle.
 */
async function parkSession(
	session: { detach: () => Promise<unknown> },
	sandboxSessionId: string,
	debug: boolean,
): Promise<SessionResumeHandle | null> {
	try {
		const state = await session.detach();
		return {
			harnessSessionId: sandboxSessionId,
			resumeState: JSON.stringify(state),
		};
	} catch (error) {
		if (debug)
			console.error(`[dbg detach failed] ${asText((error as Error)?.message)}`);
		return null;
	}
}
