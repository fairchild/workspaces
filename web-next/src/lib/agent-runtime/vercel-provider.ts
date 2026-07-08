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
import { TERMINAL_INSTALL_SCRIPT } from "../terminal/install";
import type {
	ComputeProvider,
	SessionResumeHandle,
	TurnRepo,
	TurnRequest,
} from "./provider";
import type { StreamChunk } from "./stream-chunk";

// Type-only imports of the lazily-loaded factories keep the seam light (no
// eager harness load) while giving the shared builders real signatures.
type CreateClaudeCode =
	typeof import("@ai-sdk/harness-claude-code")["createClaudeCode"];
type CreateVercelSandbox =
	typeof import("@ai-sdk/sandbox-vercel")["createVercelSandbox"];

/** Fallback repo for repo-less API-created sessions. */
const FALLBACK_TARGET_REPO =
	process.env.AGENT_TARGET_REPO ?? "fairchild/workspaces";
/** Port the in-sandbox harness bridge binds; must be declared on the sandbox. */
const BRIDGE_PORT = 4000;
/**
 * Port the in-sandbox ttyd terminal binds (#752) — declared on the sandbox so
 * `sandbox.domain(TERMINAL_PORT)` publishes it; the terminal routes attach a
 * shell to the SAME sandbox the session's turns run in (the shared-sandbox
 * pattern). Sandboxes created before this port was declared have no terminal;
 * the drawer reports that calmly rather than booting anything.
 */
export const TERMINAL_PORT = 7681;
/**
 * Max sandbox lifetime. Also the resume window: a parked (detached) session
 * reconnects only while its sandbox is still alive, so this bounds how long a
 * conversation can idle between turns before the next turn re-clones fresh.
 */
const SANDBOX_TIMEOUT_MS = 30 * 60 * 1000;
/** The persistent per-session working copy: name under the sandbox default cwd. */
const WORKSPACE_DIR_NAME = "workspace";
/** Absolute path to that working copy (sandbox default cwd is /vercel/sandbox).
 * Exported so the terminal (#752) opens its shell in the same working copy. */
export const WORKSPACE_DIR = `/vercel/sandbox/${WORKSPACE_DIR_NAME}`;
/**
 * Stable template name so `runTurn` and `prewarmVercelTemplate` target the same
 * named snapshot; the harness reuses a template only when the sandbox identity
 * matches, and the name is part of that identity.
 */
const TEMPLATE_NAME = "web-next-claude-code";
/**
 * Bump whenever the `onBootstrap` side effects change — it invalidates the
 * reusable snapshot so the next prewarm (or first turn) rebuilds the template.
 * v2: + ttyd/tmux static binaries for the terminal drawer (#752), and the
 * sandbox now declares TERMINAL_PORT (a fresh template picks that up too).
 */
const BOOTSTRAP_HASH = "claude-code-cli-v2-terminal";

// GitHub owner/name shape only. Session creation performs existence/access
// validation; the provider repeats this cheap shape guard before interpolating
// into the setup script.
const REPO_FULL_NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]+$/;

type TargetRepoResolution =
	| { ok: true; repo: TurnRepo }
	| { ok: false; error: string };

export function resolveTargetRepo(
	request: Pick<TurnRequest, "repo">,
): TargetRepoResolution {
	const candidate = request.repo ?? {
		fullName: FALLBACK_TARGET_REPO,
		defaultBranch: null,
	};
	if (
		typeof candidate.fullName !== "string" ||
		!REPO_FULL_NAME.test(candidate.fullName)
	) {
		return {
			ok: false,
			error: `invalid repository full name for agent runtime: ${JSON.stringify(candidate.fullName)}`,
		};
	}
	return {
		ok: true,
		repo: {
			fullName: candidate.fullName,
			defaultBranch:
				typeof candidate.defaultBranch === "string"
					? candidate.defaultBranch
					: null,
		},
	};
}

/** A stable per-session branch the agent commits and opens its PR from. */
export function sessionBranch(sessionId: string): string {
	return `agent/session-${sessionId.slice(0, 8)}`;
}

function shellQuote(value: string): string {
	return `'${value.replace(/'/g, "'\\''")}'`;
}

/**
 * The per-session setup script, run on every turn (fresh and resumed). It
 * configures git identity + a credential store from $GH_TOKEN (passed via the
 * command environment, never interpolated), drops the token at /tmp/gh_token for
 * the PR API, then clones the target repo into the persistent workspace and
 * creates the session branch — all idempotent, so a resumed sandbox with the
 * clone already present is a no-op and a fresh fallback sandbox re-clones.
 */
export function buildSessionSetupScript(
	sessionId: string,
	repo: TurnRepo,
): string {
	const branch = sessionBranch(sessionId);
	const branchArg = shellQuote(branch);
	const repoUrl = `https://github.com/${repo.fullName}.git`;
	const remoteRefspec = shellQuote(
		`refs/heads/${branch}:refs/remotes/origin/${branch}`,
	);
	const remoteBranchArg = shellQuote(`origin/${branch}`);
	return [
		"set -e",
		"umask 077",
		'printf "https://x-access-token:%s@github.com\\n" "$GH_TOKEN" > "$HOME/.git-credentials"',
		"git config --global credential.helper store",
		"git config --global user.name 'web-next agent'",
		"git config --global user.email 'agent@users.noreply.github.com'",
		'printf "%s" "$GH_TOKEN" > /tmp/gh_token',
		`if [ ! -d ${WORKSPACE_DIR}/.git ]; then`,
		`  if [ -n "$DEFAULT_BRANCH" ]; then`,
		`    git clone --depth 50 --branch "$DEFAULT_BRANCH" ${repoUrl} ${WORKSPACE_DIR}`,
		"  else",
		`    git clone --depth 50 ${repoUrl} ${WORKSPACE_DIR}`,
		"  fi",
		`  if git -C ${WORKSPACE_DIR} ls-remote --exit-code --heads origin ${branchArg} >/dev/null 2>&1; then`,
		`    git -C ${WORKSPACE_DIR} fetch --depth 50 origin ${remoteRefspec}`,
		`    git -C ${WORKSPACE_DIR} checkout ${branchArg} 2>/dev/null || git -C ${WORKSPACE_DIR} checkout -b ${branchArg} --track ${remoteBranchArg}`,
		"  else",
		`    git -C ${WORKSPACE_DIR} checkout -b ${branchArg}`,
		"  fi",
		"fi",
		`if [ -z "$DEFAULT_BRANCH" ]; then`,
		`  DEFAULT_BRANCH="$(git -C ${WORKSPACE_DIR} symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's#^origin/##' || true)"`,
		"fi",
		'printf "%s" "$DEFAULT_BRANCH" > /tmp/default_branch',
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
	let contextTokens: number | undefined;
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
				// `LanguageModelV4Usage` (@ai-sdk/provider) nests both figures under
				// `{ total, ... }`, not a bare number — confirmed against the
				// installed harness's own zod schema (harnessV1FinishPartSchema).
				const usage = part.totalUsage as
					| {
							inputTokens?: { total?: number };
							outputTokens?: { total?: number };
					  }
					| undefined;
				outputTokens = usage?.outputTokens?.total;
				// The turn's total input tokens is the best available proxy for
				// "current context window usage" — it's what the model actually saw
				// on this call, which for a resumed conversation is the accumulated
				// history. Real, not a placeholder; see status-line wiring in #824.
				contextTokens = usage?.inputTokens?.total;
				break;
			}
			default:
				break; // structural parts — the adapter reconstructs framing
		}
	}
	yield {
		type: "done",
		content: "",
		metadata: {
			durationMs: Date.now() - startedAt,
			tokenCount: outputTokens,
			contextTokens,
		},
	};
}

/**
 * The turn prompt. It drives the agent with the user's actual message against
 * the persistent workspace clone. A fresh session gets a one-time preamble
 * establishing where the working copy lives and how to open a PR; a resumed
 * session already carries that context in its harness conversation, so it
 * receives the user's message alone. If a warm resume failed but the durable
 * log has history, the fresh prompt also replays compact prior dialogue.
 */
function baseBranchLabel(repo: TurnRepo): string {
	return repo.defaultBranch
		? `\`${repo.defaultBranch}\``
		: "the clone's default HEAD (`cat /tmp/default_branch`)";
}

function promptCurlBase(repo: TurnRepo): string {
	return repo.defaultBranch ?? "$(cat /tmp/default_branch)";
}

export function buildPrompt(
	userMessage: string,
	sessionId: string,
	firstTurn: boolean,
	repo: TurnRepo,
	priorContext?: string | null,
): string {
	if (!firstTurn) return userMessage;
	const branch = sessionBranch(sessionId);
	const base = promptCurlBase(repo);
	const baseLabel = baseBranchLabel(repo);
	const baseAssignment = repo.defaultBranch
		? `BASE_BRANCH=${shellQuote(base)}`
		: `BASE_BRANCH="${base}"`;
	const replay = priorContext?.trim();
	if (replay) {
		return [
			`You are working inside a persistent clone of the GitHub repository ${repo.fullName}. The current directory (${WORKSPACE_DIR}) is the repo root, checked out on branch \`${branch}\`, created from ${baseLabel}. This workspace and our conversation persist across turns — later messages continue in the same working copy.`,
			``,
			`Working notes:`,
			`- Relative paths and git commands resolve against the repo (you are inside it) — edit and \`git status\`/\`git diff\` normally.`,
			`- To open or update a pull request: commit, \`git push -u origin HEAD\`, then call the GitHub API with the token in /tmp/gh_token against base ${baseLabel}, e.g. \`${baseAssignment}; curl -sS -X POST -H "Authorization: Bearer $(cat /tmp/gh_token)" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${repo.fullName}/pulls -d "{\\"title\\":\\"…\\",\\"head\\":\\"${branch}\\",\\"base\\":\\"$BASE_BRANCH\\",\\"body\\":\\"…\\"}"\`. Report the \`html_url\`.`,
			`- Only open a PR when the request calls for one; otherwise just do the work and summarize it.`,
			``,
			`The conversation so far (the sandbox restarted; your working copy was restored from the session branch):`,
			replay,
			``,
			`The user's request:`,
			userMessage,
		].join("\n");
	}
	return [
		`You are working inside a persistent clone of the GitHub repository ${repo.fullName}. The current directory (${WORKSPACE_DIR}) is the repo root, checked out on branch \`${branch}\`, created from ${baseLabel}. This workspace and our conversation persist across turns — later messages continue in the same working copy.`,
		``,
		`Working notes:`,
		`- Relative paths and git commands resolve against the repo (you are inside it) — edit and \`git status\`/\`git diff\` normally.`,
		`- To open or update a pull request: commit, \`git push -u origin HEAD\`, then call the GitHub API with the token in /tmp/gh_token against base ${baseLabel}, e.g. \`${baseAssignment}; curl -sS -X POST -H "Authorization: Bearer $(cat /tmp/gh_token)" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${repo.fullName}/pulls -d "{\\"title\\":\\"…\\",\\"head\\":\\"${branch}\\",\\"base\\":\\"$BASE_BRANCH\\",\\"body\\":\\"…\\"}"\`. Report the \`html_url\`.`,
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

/**
 * The claude-code harness adapter. Identical inputs on both paths, plus an
 * optional per-turn model override (#824): `settings.model` forwards
 * unchanged onto the sandbox bridge's `claudeSdk.query({ options: { model } })`
 * call (verified against the installed `@ai-sdk/harness-claude-code` bundle —
 * no enum/allowlist at that layer), so any id from `./models.ts` works. Model
 * is deliberately NOT part of the reusable sandbox template identity
 * (`SANDBOX_BOOTSTRAP`/`BOOTSTRAP_HASH`) — it only affects which model the CLI
 * invokes inside an already-warm sandbox, so per-session model choice never
 * invalidates the shared snapshot prewarm builds.
 */
export function createHarness(
	createClaudeCode: CreateClaudeCode,
	auth: ReturnType<typeof resolveAuth>,
	model?: string,
) {
	return createClaudeCode({ auth, thinking: "on", ...(model ? { model } : {}) });
}

/** The Vercel sandbox naming scheme the adapter uses for per-session sandboxes. */
const SESSION_SANDBOX_PREFIX = "ai-sdk-harness-session";

/**
 * The Vercel sandbox name a parked harness session lives under — the same
 * derivation the adapter's resume path uses, exported so the terminal routes
 * (#752) can attach to the LIVE sandbox of a session and nothing else.
 */
export function sessionSandboxName(harnessSessionId: string): string {
	return `${SESSION_SANDBOX_PREFIX}-${harnessSessionId}`;
}

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
		ports: [BRIDGE_PORT, TERMINAL_PORT],
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
				name: sessionSandboxName(sessionId),
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
		// Bake the terminal binaries (ttyd + tmux, #752) into the snapshot so
		// drawer-open doesn't pay the download. Best-effort: a transient fetch
		// failure must never block the chat path — the terminal mint route
		// re-runs the same idempotent script as a fallback.
		try {
			const res = await session.run({ command: TERMINAL_INSTALL_SCRIPT });
			if (res.exitCode !== 0 && process.env.HARNESS_DEBUG === "1")
				console.error(
					`[dbg onBootstrap] terminal install failed (exit ${res.exitCode}): ${res.stderr.slice(0, 200)}`,
				);
		} catch {
			// best-effort — the mint route re-runs the same idempotent script
		}
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
		const targetRepo = resolveTargetRepo(request);
		if (!targetRepo.ok) {
			yield {
				type: "error",
				content: targetRepo.error,
				metadata: { code: "invalid_repo" },
			};
			yield {
				type: "done",
				content: "",
				metadata: { durationMs: Date.now() - startedAt, aborted: true },
			};
			return;
		}
		const repo = targetRepo.repo;

		yield { type: "status", content: "Minting GitHub credential" };
		const { token } = await mintInstallationToken(repo.fullName);

		yield { type: "status", content: "Preparing sandbox runtime" };
		const [{ HarnessAgent }, { createClaudeCode }, { createVercelSandbox }] =
			await Promise.all([
				import("@ai-sdk/harness/agent"),
				import("@ai-sdk/harness-claude-code"),
				import("@ai-sdk/sandbox-vercel"),
			]);

		const debugHarness = process.env.HARNESS_DEBUG === "1";

		// The sandbox session is captured here so the turn can run `git diff` after
		// streaming to synthesize Diff ledger rows (the harness session drives
		// turns, not arbitrary commands). The sandbox stays alive until detach, so
		// it is valid through the end of the turn.
		let sandbox: RunnableSandbox | undefined;

		const agent = new HarnessAgent({
			id: `web-next-${request.sessionId}`,
			harness: createHarness(createClaudeCode, resolveAuth(), request.model),
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
						content: buildSessionSetupScript(request.sessionId, repo),
					});
					const res = await session.run({
						command: "bash /tmp/session-setup.sh",
						env: {
							GH_TOKEN: token,
							DEFAULT_BRANCH: repo.defaultBranch ?? "",
						},
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
		const replayContext = request.priorContext?.trim();
		let replayStatusEmitted = false;
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
				if (replayContext) {
					yield {
						type: "status",
						content: "Restored conversation context from the session log",
					};
					replayStatusEmitted = true;
				}
			}
		}
		if (!session) {
			if (replayContext && !replayStatusEmitted) {
				yield {
					type: "status",
					content: "Restored conversation context from the session log",
				};
				replayStatusEmitted = true;
			}
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
				prompt: buildPrompt(
					request.userMessage,
					request.sessionId,
					!resumed,
					repo,
					!resumed ? replayContext : null,
				),
			});
			let doneChunk: StreamChunk | undefined;
			// Tracks every real toolCallId this turn so the synthetic Diff rows
			// below can't collide with one — the AI SDK upserts dynamic-tool parts
			// by toolCallId, so a collision would silently overwrite a real tool's
			// result instead of adding a second row.
			const seenToolCallIds = new Set<string>();
			for await (const chunk of mapFullStream(
				result.fullStream as AsyncIterable<{ type: string; [k: string]: unknown }>,
				startedAt,
			)) {
				if (chunk.type === "done") {
					doneChunk = chunk;
					break; // the terminal chunk — emit Diff rows, then park, then it
				}
				const id = chunk.metadata?.toolUseId;
				if (typeof id === "string") seenToolCallIds.add(id);
				yield chunk;
			}
			const tail = runTurnTail({
				sandbox,
				branch: sessionBranch(request.sessionId),
				seenToolCallIds,
				doneChunk,
				session,
				sandboxSessionId,
				debug: debugHarness,
			});
			for (;;) {
				const next = await tail.next();
				if (next.done) {
					detached = next.value;
					break;
				}
				yield next.value;
			}
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

/**
 * A synthetic diff row's id, disambiguated against any real toolCallId
 * already seen this turn. In practice a real id (the model provider's own
 * tool-use id) never looks like `diff:<path>`, but the id space is shared
 * with real tool calls, so this guards the collision explicitly rather than
 * assuming it can't happen.
 */
export function uniqueDiffToolCallId(file: string, seen: ReadonlySet<string>): string {
	let id = `diff:${file}`;
	for (let suffix = 1; seen.has(id); suffix += 1) id = `diff:${file}#${suffix}`;
	return id;
}

/** A sandbox session that can run shell commands (the onSession surface). */
export interface RunnableSandbox {
	run: (opts: {
		command: string;
	}) => PromiseLike<{ exitCode: number; stdout: string; stderr: string }>;
}

/** One changed file's diff: file, line counts, and the hunk lines. */
interface FileDiff {
	file: string;
	additions: number;
	deletions: number;
	note: string;
	lines: { kind: "add" | "del" | "context"; text: string }[];
}

/** Beyond this many hunk lines a single file's diff is truncated. */
const DIFF_LINE_CAP = 200;

/**
 * Runs `git diff` over the workspace (untracked files marked intent-to-add so
 * new files show) and parses it into one diff per changed file. Best-effort —
 * any failure yields no diffs, never breaking the turn.
 */
async function changedFileDiffs(sandbox: RunnableSandbox | undefined): Promise<FileDiff[]> {
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

const CHECKPOINT_COMMIT_MESSAGE = "wip(session): checkpoint after turn";
const CHECKPOINT_ERROR_CAP = 240;

function commandFailure(
	label: string,
	res: { exitCode: number; stdout: string; stderr: string },
): Error {
	const detail = [res.stderr.trim(), res.stdout.trim()].filter(Boolean).join("\n");
	return new Error(
		`${label} failed (exit ${res.exitCode})${detail ? `: ${detail}` : ""}`,
	);
}

async function runRequired(
	sandbox: RunnableSandbox,
	label: string,
	command: string,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
	const res = await sandbox.run({ command });
	if (res.exitCode !== 0) throw commandFailure(label, res);
	return res;
}

function capCheckpointError(value: unknown): string {
	const text = errorText(value).replace(/\s+/g, " ").trim() || "unknown error";
	if (text.length <= CHECKPOINT_ERROR_CAP) return text;
	return `${text.slice(0, CHECKPOINT_ERROR_CAP - 3)}...`;
}

async function unpushedCommitCount(
	sandbox: RunnableSandbox,
	branch: string,
): Promise<number> {
	const branchArg = shellQuote(branch);
	const remoteRef = `refs/remotes/origin/${branch}`;
	const remoteExists = await sandbox.run({
		command: `git -C ${WORKSPACE_DIR} ls-remote --exit-code --heads origin ${branchArg} >/dev/null`,
	});
	let baseRef: string;
	if (remoteExists.exitCode === 0) {
		await runRequired(
			sandbox,
			"checkpoint fetch",
			`git -C ${WORKSPACE_DIR} fetch --depth 50 origin ${shellQuote(`refs/heads/${branch}:refs/remotes/origin/${branch}`)}`,
		);
		baseRef = remoteRef;
	} else if (remoteExists.exitCode === 2) {
		baseRef = "origin/HEAD";
	} else {
		throw commandFailure("checkpoint remote branch check", remoteExists);
	}

	const ahead = await runRequired(
		sandbox,
		"checkpoint ahead check",
		`git -C ${WORKSPACE_DIR} rev-list --count ${shellQuote(`${baseRef}..HEAD`)}`,
	);
	const count = Number.parseInt(ahead.stdout.trim(), 10);
	if (!Number.isFinite(count)) {
		throw new Error(`checkpoint ahead check returned ${JSON.stringify(ahead.stdout)}`);
	}
	return count;
}

/**
 * Best-effort end-of-turn preservation. It records dirty work as a WIP commit
 * and pushes the session branch when local commits are ahead of the remote.
 * Failures become calm status chunks; they never fail the agent turn.
 */
export async function checkpointSessionBranch(
	sandbox: RunnableSandbox | undefined,
	branch: string,
): Promise<string | undefined> {
	if (!sandbox) return undefined;
	try {
		const status = await runRequired(
			sandbox,
			"checkpoint status",
			`git -C ${WORKSPACE_DIR} status --porcelain=v1`,
		);
		const hasTreeChanges = status.stdout.trim().length > 0;
		if (hasTreeChanges) {
			await runRequired(
				sandbox,
				"checkpoint add",
				`git -C ${WORKSPACE_DIR} add -A`,
			);
			const staged = await runRequired(
				sandbox,
				"checkpoint staged check",
				[
					"set +e",
					`git -C ${WORKSPACE_DIR} diff --cached --quiet`,
					"code=$?",
					"set -e",
					'if [ "$code" -eq 0 ]; then printf clean; elif [ "$code" -eq 1 ]; then printf dirty; else exit "$code"; fi',
				].join("; "),
			);
			if (staged.stdout.trim() === "dirty") {
				await runRequired(
					sandbox,
					"checkpoint commit",
					`git -C ${WORKSPACE_DIR} commit -m ${shellQuote(CHECKPOINT_COMMIT_MESSAGE)}`,
				);
			}
		}

		const ahead = await unpushedCommitCount(sandbox, branch);
		if (ahead <= 0) return undefined;

		await runRequired(
			sandbox,
			"checkpoint push",
			`git -C ${WORKSPACE_DIR} push -u origin ${shellQuote(branch)}`,
		);
		return `Pushed checkpoint to ${branch}`;
	} catch (error) {
		return `Checkpoint push failed: ${capCheckpointError(error)}`;
	}
}

export interface TurnTailOptions {
	sandbox: RunnableSandbox | undefined;
	branch: string;
	seenToolCallIds: Set<string>;
	doneChunk: StreamChunk | undefined;
	session: { detach: () => Promise<unknown> };
	sandboxSessionId: string;
	debug: boolean;
}

export async function* runTurnTail({
	sandbox,
	branch,
	seenToolCallIds,
	doneChunk,
	session,
	sandboxSessionId,
	debug,
}: TurnTailOptions): AsyncGenerator<StreamChunk, boolean, void> {
	// Synthesize one Diff ledger row per changed file from the working tree
	// (the Edit/Write results carry no patch; the real diff lives in git).
	// Emitted as a tool_use + tool_result pair — the Folio adapter merges
	// metadata.diff into that same call's own output (#790: a diff's home
	// is its own expandable ledger row, never a separate floating card),
	// and the AI SDK only keeps a tool result that has a matching opened
	// call. This is a per-file summary, not per Edit invocation — git diff
	// can't attribute hunks back to individual tool calls when a file is
	// edited more than once in a turn, so multiple edits to one file land
	// as a single Diff row rather than each Edit call carrying its own.
	for (const diff of await changedFileDiffs(sandbox)) {
		const toolUseId = uniqueDiffToolCallId(diff.file, seenToolCallIds);
		seenToolCallIds.add(toolUseId);
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

	const checkpointStatus = await checkpointSessionBranch(sandbox, branch);
	if (checkpointStatus) yield { type: "status", content: checkpointStatus };

	// Park the session so the next turn reconnects it; carry the resume
	// payload out on the done chunk for the ingest loop to persist. If
	// parking fails, `resume: null` clears the stale handle and the session
	// is torn down by the caller.
	const resume = await parkSession(session, sandboxSessionId, debug);
	yield {
		...(doneChunk ?? { type: "done", content: "" }),
		metadata: { ...doneChunk?.metadata, resume },
	};
	return resume !== null;
}

/** Splits a multi-file unified diff into per-file diffs. */
export function parseGitDiff(raw: string): FileDiff[] {
	const diffs: FileDiff[] = [];
	let current: FileDiff | undefined;
	let inHunk = false;
	for (const line of raw.split("\n")) {
		if (line.startsWith("diff --git")) {
			if (current && current.lines.length > 0) diffs.push(current);
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
	if (current && current.lines.length > 0) diffs.push(current);
	return diffs;
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
