/*
 * The real compute provider: runs one Claude Code turn inside a Vercel sandbox
 * via @ai-sdk/harness and streams its parts back as StreamChunks. The sandbox is
 * created through the harness factory so its bootstrap installs the `claude` CLI
 * (and reuses a snapshot template across turns); a per-session `onSession` hook
 * injects the GitHub App installation token as a git credential — the token
 * rides in via the command `env`, never the transcript — so the agent can clone,
 * push, and open a PR against the target repo. The model authenticates through
 * the AI Gateway. Heavy deps load lazily so the seam stays light for the mock
 * path; sessions opt in via sessions.provider = "vercel".
 */
import type { HarnessAgentSandboxConfig } from "@ai-sdk/harness/agent";
import { mintInstallationToken } from "../diag/github-app";
import type { ComputeProvider, TurnRequest } from "./provider";
import type { StreamChunk } from "./stream-chunk";

// Type-only imports of the lazily-loaded factories keep the seam light (no
// eager harness load) while giving the shared builders real signatures.
type CreateClaudeCode =
	typeof import("@ai-sdk/harness-claude-code")["createClaudeCode"];
type CreateVercelSandbox =
	typeof import("@ai-sdk/sandbox-vercel")["createVercelSandbox"];

/** Repo the agent clones and opens its PR against. */
const TARGET_REPO = process.env.AGENT_TARGET_REPO ?? "fairchild/workspaces";
/** Port the in-sandbox harness bridge binds; must be declared on the sandbox. */
const BRIDGE_PORT = 4000;
const SANDBOX_TIMEOUT_MS = 15 * 60 * 1000;
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

/**
 * A self-contained setup script written into the sandbox and run once per
 * session. It configures git identity and a credential store from $GH_TOKEN
 * (passed via the command environment, not interpolated here) so clone/push
 * authenticate, and drops the same token at /tmp/gh_token for the PR API call.
 */
const GIT_SETUP_SCRIPT = [
	"set -e",
	"umask 077",
	'printf "https://x-access-token:%s@github.com\\n" "$GH_TOKEN" > "$HOME/.git-credentials"',
	"git config --global credential.helper store",
	"git config --global user.name 'web-next agent'",
	"git config --global user.email 'agent@users.noreply.github.com'",
	'printf "%s" "$GH_TOKEN" > /tmp/gh_token',
	"",
].join("\n");

function asText(value: unknown): string {
	if (typeof value === "string") return value;
	try {
		return JSON.stringify(value);
	} catch {
		return String(value);
	}
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
		if (process.env.HARNESS_DEBUG === "1")
			console.error(`[dbg part] ${part.type} ${JSON.stringify(part).slice(0, 240)}`);
		switch (part.type) {
			case "text-delta":
				if (part.text) yield { type: "text", content: part.text as string };
				break;
			case "reasoning-delta":
				if (part.text)
					yield { type: "reasoning", content: part.text as string };
				break;
			case "tool-call":
				yield {
					type: "tool_use",
					content: asText(part.toolName),
					metadata: {
						toolUseId: part.toolCallId,
						toolName: part.toolName,
						input: part.input,
					},
				};
				break;
			case "tool-result":
				yield {
					type: "tool_result",
					content: asText(part.output),
					metadata: { toolUseId: part.toolCallId, output: part.output },
				};
				break;
			case "tool-error":
				yield {
					type: "tool_result",
					content: asText(part.error),
					metadata: { toolUseId: part.toolCallId, isError: true },
				};
				break;
			case "error":
				yield { type: "error", content: asText(part.error) };
				break;
			case "abort":
				yield {
					type: "error",
					content: `aborted${part.reason ? `: ${asText(part.reason)}` : ""}`,
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
 * TEMPORARY (#826): a fixed clone→branch→create-marker→push→open-PR smoke
 * script. It proves the runtime plumbing end to end but does NOT yet drive the
 * turn from the user's message — `userMessage` rides in only as a marker line,
 * not as the instruction. Replacing this with a prompt driven by the user's
 * actual request (against the session's working copy) is #826, which also
 * carries the #750 render/resume/perf acceptance evidence.
 *
 * Credentials are pre-wired globally (git credential store) with the raw token
 * at /tmp/gh_token for the PR API — so the prompt names no secret.
 */
function buildPrompt(userMessage: string): string {
	const stamp = new Date().toISOString();
	const suffix = Math.random().toString(36).slice(2, 8);
	const branch = `agent/runtime-smoke-${suffix}`;
	// A fixed absolute repo dir keeps the file-edit builtins and bash in
	// agreement — they resolve different working directories otherwise.
	const repoDir = `/vercel/sandbox/repo-${suffix}`;
	const line = `- ${stamp} — first PR opened by the web-next harness runtime. Request: ${userMessage.replace(/`/g, "'").slice(0, 200)}`;
	return [
		`Open a real pull request against the GitHub repository ${TARGET_REPO}. Use the ABSOLUTE path ${repoDir} for the working copy and absolute paths for every file operation and git command (git tool calls and the file-edit tools resolve different working directories, so absolute paths keep them consistent). Work through the steps in order and stop if any command fails, showing its output.`,
		``,
		`1. Clone the repo: \`git clone https://github.com/${TARGET_REPO}.git ${repoDir}\`. Credentials are configured globally, so this authenticates automatically.`,
		`2. Create the branch: \`git -C ${repoDir} checkout -b ${branch}\`.`,
		`3. Create the file \`${repoDir}/web-next/RUNTIME-SMOKE.md\` (use an absolute path) containing exactly this line:`,
		`   ${line}`,
		`4. Commit: \`git -C ${repoDir} add -A && git -C ${repoDir} commit -m "chore(web-next): runtime smoke — harness-opened PR"\`.`,
		`5. Push the branch: \`git -C ${repoDir} push -u origin HEAD\`.`,
		`6. Open a pull request against \`main\` via the GitHub API (the token is in /tmp/gh_token):`,
		`   curl -sS -X POST -H "Authorization: Bearer $(cat /tmp/gh_token)" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${TARGET_REPO}/pulls -d '{"title":"chore(web-next): runtime smoke — harness-opened PR","head":"${branch}","base":"main","body":"Opened automatically by the web-next harness runtime — a real PR from a session. Safe to review and close."}'`,
		`7. Report the pull request URL (the \`html_url\` field of the API response).`,
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

/**
 * The Vercel sandbox provider, built via the factory path with a stable `name`
 * so `runTurn` and prewarm target the same named template snapshot.
 */
function createSandboxProvider(createVercelSandbox: CreateVercelSandbox) {
	return createVercelSandbox({
		runtime: "node22",
		ports: [BRIDGE_PORT],
		resources: { vcpus: 4 },
		timeout: SANDBOX_TIMEOUT_MS,
		token: process.env.VERCEL_TOKEN,
		teamId: process.env.VERCEL_TEAM_ID,
		projectId: process.env.VERCEL_PROJECT_ID,
		name: TEMPLATE_NAME,
	});
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

		const agent = new HarnessAgent({
			id: `web-next-${request.sessionId}`,
			harness: createHarness(createClaudeCode, resolveAuth()),
			sandbox: createSandboxProvider(createVercelSandbox),
			sandboxConfig: {
				// Same template-identity bootstrap as prewarm, plus the per-session
				// credential hook (which is deliberately excluded from the snapshot).
				...SANDBOX_BOOTSTRAP,
				onSession: async ({ session }) => {
					await session.writeTextFile({
						path: "/tmp/git-setup.sh",
						content: GIT_SETUP_SCRIPT,
					});
					const res = await session.run({
						command: "bash /tmp/git-setup.sh",
						env: { GH_TOKEN: token },
					});
					if (res.exitCode !== 0)
						throw new Error(
							`git credential setup failed (exit ${res.exitCode}): ${res.stderr.slice(0, 300)}`,
						);
					if (debugHarness) {
						const chk = await session.run({ command: "which claude" });
						console.error(
							`[dbg onSession] git configured; claude=${chk.stdout.trim() || "MISSING"} (exit ${chk.exitCode})`,
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

		yield { type: "status", content: "Booting Claude Code in sandbox" };
		const session = await agent.createSession();
		try {
			const result = await agent.stream({
				session,
				prompt: buildPrompt(request.userMessage),
			});
			yield* mapFullStream(
				result.fullStream as AsyncIterable<{ type: string; [k: string]: unknown }>,
				startedAt,
			);
		} finally {
			await session.destroy().catch(() => {});
		}
	},
};
