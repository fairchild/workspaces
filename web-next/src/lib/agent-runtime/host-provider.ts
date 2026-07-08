/*
 * Host compute provider: runs one Claude Code print-mode turn through the
 * local `claude` binary on the same machine as the web-next server. It keeps
 * the detached-turn contract identical to the sandbox provider while sharply
 * limiting host blast radius: no skip-permissions flag, read-only tools only,
 * and a curated child environment instead of the server's full process.env.
 */
import { accessSync, constants } from "node:fs";
import { access, mkdir, stat } from "node:fs/promises";
import {
	spawn,
	type ChildProcess,
	type ChildProcessWithoutNullStreams,
} from "node:child_process";
import {
	delimiter,
	dirname,
	isAbsolute,
	relative,
	resolve,
} from "node:path";
import { createInterface } from "node:readline";
import type {
	ComputeProvider,
	SessionResumeHandle,
	TurnRepo,
	TurnRequest,
} from "./provider";
import type { StreamChunk } from "./stream-chunk";
import {
	canonicalToolName,
	errorText,
	resolveTargetRepo,
	toolResultContent,
} from "./vercel-provider";

const HOST_WORKSPACE_ROOT_ENV = "WEB_NEXT_HOST_WORKSPACE_ROOT";
const HOST_CLAUDE_BIN_ENV = "WEB_NEXT_HOST_CLAUDE_BIN";
const HOST_ABORT_MESSAGE = "Turn stopped.";
const KILL_GRACE_MS = 5_000;

export const HOST_ALLOWED_TOOLS = [
	"Read",
	"LS",
	"Glob",
	"Grep",
	"WebFetch",
	"WebSearch",
	"TodoRead",
] as const;

const DANGEROUS_SKIP_FLAGS = new Set([
	"--dangerously-skip-permissions",
	"--allow-dangerously-skip-permissions",
]);

const CURATED_ENV_KEYS = new Set([
	"HOME",
	"NODE_ENV",
	"PATH",
	"SHELL",
	"USER",
	"LOGNAME",
	"TMPDIR",
	"TEMP",
	"TMP",
	"LANG",
	"LC_ALL",
	"LC_CTYPE",
	"TERM",
	"XDG_CONFIG_HOME",
	"XDG_CACHE_HOME",
	"XDG_DATA_HOME",
	"ANTHROPIC_API_KEY",
	"ANTHROPIC_AUTH_TOKEN",
	"ANTHROPIC_BASE_URL",
	"ANTHROPIC_CUSTOM_HEADERS",
	"CLAUDE_CODE_OAUTH_TOKEN",
	"CLAUDE_CODE_API_KEY_HELPER",
	"CLAUDE_CONFIG_DIR",
]);

type ProviderFailureCode =
	| "host_workspace_root_unset"
	| "invalid_repo"
	| "invalid_session_id"
	| "host_claude_missing"
	| "host_workspace_setup_failed"
	| "host_claude_failed";

interface HostFailure {
	code: ProviderFailureCode;
	message: string;
}

interface ExitStatus {
	code: number | null;
	signal: NodeJS.Signals | null;
}

interface ClaudeEvent {
	type?: unknown;
	subtype?: unknown;
	session_id?: unknown;
	message?: {
		content?: unknown;
		usage?: unknown;
	};
	is_error?: unknown;
	result?: unknown;
	error?: unknown;
	duration_ms?: unknown;
	durationMs?: unknown;
	usage?: unknown;
}

interface HostDoneMeta {
	durationMs: number;
	tokenCount?: number;
	contextTokens?: number;
	aborted?: boolean;
	resume?: SessionResumeHandle | null;
}

function failureChunk(failure: HostFailure): StreamChunk {
	return {
		type: "error",
		content: failure.message,
		metadata: { code: failure.code },
	};
}

function doneChunk(
	startedAt: number,
	metadata: Partial<HostDoneMeta> = {},
): StreamChunk {
	const clean: Record<string, unknown> = { durationMs: Date.now() - startedAt };
	for (const [key, value] of Object.entries(metadata)) {
		if (value !== undefined) clean[key] = value;
	}
	return {
		type: "done",
		content: "",
		metadata: clean,
	};
}

function abortedDone(startedAt: number): StreamChunk {
	return doneChunk(startedAt, { aborted: true });
}

function isMissingPath(error: unknown): boolean {
	return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}

function executableInPath(command: string, pathValue: string): string | null {
	for (const dir of pathValue.split(delimiter)) {
		if (!dir) continue;
		const candidate = resolve(dir, command);
		try {
			accessSync(candidate, constants.X_OK);
			return candidate;
		} catch {
			// Keep searching PATH.
		}
	}
	return null;
}

export async function resolveClaudeBinary(
	env: NodeJS.ProcessEnv = process.env,
): Promise<string | HostFailure> {
	const configured = env[HOST_CLAUDE_BIN_ENV]?.trim();
	if (configured) {
		const candidate = configured.includes("/")
			? configured
			: executableInPath(configured, env.PATH ?? "");
		if (!candidate) {
			return {
				code: "host_claude_missing",
				message: `${HOST_CLAUDE_BIN_ENV} is set to ${JSON.stringify(configured)}, but that executable was not found`,
			};
		}
		try {
			await access(candidate, constants.X_OK);
			return candidate;
		} catch {
			return {
				code: "host_claude_missing",
				message: `${HOST_CLAUDE_BIN_ENV} is set to ${JSON.stringify(configured)}, but it is not executable`,
			};
		}
	}

	const found = executableInPath("claude", env.PATH ?? "");
	if (found) return found;
	return {
		code: "host_claude_missing",
		message:
			"claude binary not found; set WEB_NEXT_HOST_CLAUDE_BIN or add claude to PATH",
	};
}

export function curatedClaudeEnv(
	source: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {
		NODE_ENV: source.NODE_ENV ?? "production",
	};
	for (const key of CURATED_ENV_KEYS) {
		const value = source[key];
		if (value !== undefined) env[key] = value;
	}
	return env;
}

export function resolveHostWorkspaceDir(
	sessionId: string,
	env: NodeJS.ProcessEnv = process.env,
): string | HostFailure {
	const root = env[HOST_WORKSPACE_ROOT_ENV]?.trim();
	if (!root) {
		return {
			code: "host_workspace_root_unset",
			message: `${HOST_WORKSPACE_ROOT_ENV} must be set for the host compute provider`,
		};
	}
	const resolvedRoot = resolve(root);
	const workspaceDir = resolve(resolvedRoot, sessionId);
	const rel = relative(resolvedRoot, workspaceDir);
	if (
		sessionId.length === 0 ||
		rel.length === 0 ||
		rel.startsWith("..") ||
		isAbsolute(rel)
	) {
		return {
			code: "invalid_session_id",
			message: `session id is not safe for a host workspace path: ${JSON.stringify(sessionId)}`,
		};
	}
	return workspaceDir;
}

export function buildHostCloneArgs(repo: TurnRepo, workspaceDir: string): string[] {
	const args = ["clone", "--depth", "50"];
	if (repo.defaultBranch) args.push("--branch", repo.defaultBranch);
	args.push(`https://github.com/${repo.fullName}.git`, workspaceDir);
	return args;
}

async function runCommand(
	command: string,
	args: string[],
	options: { cwd?: string; env?: NodeJS.ProcessEnv; signal?: AbortSignal } = {},
): Promise<{ ok: true } | { ok: false; stderr: string; code: number | null }> {
	const child = spawn(command, args, {
		cwd: options.cwd,
		env: options.env ?? curatedClaudeEnv(),
		stdio: ["ignore", "ignore", "pipe"],
	});
	let stderr = "";
	child.stderr?.setEncoding("utf8");
	child.stderr?.on("data", (chunk: string) => {
		stderr += chunk;
	});
	const stop = () => terminateChild(child);
	options.signal?.addEventListener("abort", stop, { once: true });
	try {
		const exit = await waitForExit(child);
		return exit.code === 0
			? { ok: true }
			: { ok: false, stderr: stderr.trim(), code: exit.code };
	} catch (error) {
		return { ok: false, stderr: errorText(error), code: null };
	} finally {
		options.signal?.removeEventListener("abort", stop);
	}
}

async function ensureWorkspace(
	workspaceDir: string,
	repo: TurnRepo,
	signal?: AbortSignal,
): Promise<HostFailure | null> {
	try {
		const existing = await stat(workspaceDir);
		if (!existing.isDirectory()) {
			return {
				code: "host_workspace_setup_failed",
				message: `host workspace path exists but is not a directory: ${workspaceDir}`,
			};
		}
		return null;
	} catch (error) {
		if (!isMissingPath(error)) {
			return {
				code: "host_workspace_setup_failed",
				message: `cannot inspect host workspace ${workspaceDir}: ${errorText(error)}`,
			};
		}
	}

	await mkdir(dirname(workspaceDir), { recursive: true });
	const clone = await runCommand("git", buildHostCloneArgs(repo, workspaceDir), {
		env: curatedClaudeEnv(),
		signal,
	});
	if (clone.ok) return null;
	return {
		code: "host_workspace_setup_failed",
		message: `git clone failed for ${repo.fullName} (exit ${clone.code ?? "unknown"}): ${clone.stderr || "no stderr"}`,
	};
}

export function buildHostPrompt(
	request: Pick<TurnRequest, "userMessage" | "resume" | "priorContext">,
	repoFullName: string,
	workspaceDir: string,
): string {
	if (request.resume) return request.userMessage;
	const replay = request.priorContext?.trim();
	const lines = [
		`You are working inside a persistent host clone of the GitHub repository ${repoFullName}. The current directory (${workspaceDir}) is the repo root. This host provider is currently restricted to read-only tools until the approval protocol is integrated, so inspect and reason about the workspace but do not edit files, commit, push, or open pull requests.`,
		"",
		"The user's request:",
		request.userMessage,
	];
	if (replay) {
		lines.splice(
			2,
			0,
			"The conversation so far (the local Claude session restarted; continue from this compact transcript):",
			replay,
			"",
		);
	}
	return lines.join("\n");
}

export function buildClaudeArgs(
	request: Pick<TurnRequest, "model" | "resume">,
): string[] {
	const args = [
		"-p",
		"--output-format",
		"stream-json",
		"--verbose",
		"--allowedTools",
		HOST_ALLOWED_TOOLS.join(","),
		"--permission-mode",
		"dontAsk",
	];
	if (request.model) args.push("--model", request.model);
	if (request.resume?.harnessSessionId) {
		args.push("--resume", request.resume.harnessSessionId);
	}
	for (const arg of args) {
		if (DANGEROUS_SKIP_FLAGS.has(arg)) {
			throw new Error(`host provider must not pass ${arg}`);
		}
	}
	return args;
}

function appendContentText(value: unknown): string {
	if (typeof value === "string") return value;
	if (Array.isArray(value)) {
		return value
			.map((part) => {
				if (typeof part === "string") return part;
				if (part && typeof part === "object" && "text" in part) {
					return String((part as { text?: unknown }).text ?? "");
				}
				return "";
			})
			.join("");
	}
	if (value == null) return "";
	return toolResultContent(value);
}

function usageNumber(usage: unknown, key: string): number | undefined {
	if (!usage || typeof usage !== "object") return undefined;
	const value = (usage as Record<string, unknown>)[key];
	return typeof value === "number" ? value : undefined;
}

function resumeFor(sessionId: string | undefined): SessionResumeHandle | null {
	if (!sessionId) return null;
	return {
		harnessSessionId: sessionId,
		resumeState: JSON.stringify({ provider: "host", sessionId }),
	};
}

export function mapClaudeJsonEvent(event: unknown): {
	chunks: StreamChunk[];
	sessionId?: string;
	done?: { metadata: Partial<HostDoneMeta> };
} {
	if (!event || typeof event !== "object") return { chunks: [] };
	const e = event as ClaudeEvent;
	const chunks: StreamChunk[] = [];
	const sessionId = typeof e.session_id === "string" ? e.session_id : undefined;

	if (e.type === "assistant") {
		const content = e.message?.content;
		if (typeof content === "string") {
			if (content) chunks.push({ type: "text", content });
		} else if (Array.isArray(content)) {
			for (const part of content) {
				if (!part || typeof part !== "object") continue;
				const p = part as Record<string, unknown>;
				switch (p.type) {
					case "text":
						if (typeof p.text === "string" && p.text) {
							chunks.push({ type: "text", content: p.text });
						}
						break;
					case "thinking":
					case "reasoning":
						if (typeof p.thinking === "string" && p.thinking) {
							chunks.push({ type: "reasoning", content: p.thinking });
						} else if (typeof p.text === "string" && p.text) {
							chunks.push({ type: "reasoning", content: p.text });
						}
						break;
					case "tool_use":
					case "server_tool_use": {
						const toolName = canonicalToolName(p.name);
						chunks.push({
							type: "tool_use",
							content: toolName,
							metadata: {
								toolUseId: p.id,
								toolName,
								input: p.input,
							},
						});
						break;
					}
					default:
						break;
				}
			}
		}
		return { chunks, sessionId };
	}

	if (e.type === "user") {
		const content = e.message?.content;
		if (Array.isArray(content)) {
			for (const part of content) {
				if (!part || typeof part !== "object") continue;
				const p = part as Record<string, unknown>;
				if (p.type !== "tool_result") continue;
				const text = appendContentText(p.content);
				chunks.push({
					type: "tool_result",
					content: text,
					metadata: {
						toolUseId: p.tool_use_id,
						output: text,
						...(p.is_error ? { isError: true } : {}),
					},
				});
			}
		}
		return { chunks, sessionId };
	}

	if (e.type === "error") {
		return {
			chunks: [{ type: "error", content: errorText(e.error ?? e.result) }],
			sessionId,
		};
	}

	if (e.type === "result") {
		const usage = e.usage ?? e.message?.usage;
		const tokenCount = usageNumber(usage, "output_tokens");
		const inputTokens = usageNumber(usage, "input_tokens");
		const cacheCreationTokens =
			usageNumber(usage, "cache_creation_input_tokens") ?? 0;
		const cacheReadTokens = usageNumber(usage, "cache_read_input_tokens") ?? 0;
		const contextTokens =
			inputTokens === undefined
				? undefined
				: inputTokens + cacheCreationTokens + cacheReadTokens;
		if (e.is_error || e.subtype === "error") {
			chunks.push({ type: "error", content: errorText(e.result ?? e.error) });
		}
		return {
			chunks,
			sessionId,
			done: {
				metadata: {
					durationMs:
						typeof e.duration_ms === "number"
							? e.duration_ms
							: typeof e.durationMs === "number"
								? e.durationMs
								: undefined,
					tokenCount,
					contextTokens,
					aborted: Boolean(e.is_error || e.subtype === "error") || undefined,
				},
			},
		};
	}

	return { chunks, sessionId };
}

function waitForExit(child: ChildProcess): Promise<ExitStatus> {
	return new Promise((resolve, reject) => {
		child.once("error", reject);
		child.once("close", (code, signal) => resolve({ code, signal }));
	});
}

function terminateChild(child: ChildProcess): void {
	if (child.exitCode !== null || child.signalCode !== null) return;
	child.kill("SIGTERM");
	setTimeout(() => {
		if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
	}, KILL_GRACE_MS).unref();
}

function capStderr(stderr: string): string {
	const trimmed = stderr.trim();
	return trimmed.length <= 800 ? trimmed : `${trimmed.slice(0, 797)}...`;
}

async function* streamClaudeProcess(
	child: ChildProcessWithoutNullStreams,
	startedAt: number,
): AsyncGenerator<StreamChunk, { closed: boolean; sessionId?: string }, void> {
	const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
	let cliSessionId: string | undefined;
	let closed = false;
	for await (const raw of rl) {
		const line = raw.trim();
		if (!line) continue;
		let event: unknown;
		try {
			event = JSON.parse(line);
		} catch (error) {
			yield {
				type: "error",
				content: `invalid claude stream-json line: ${errorText(error)}`,
				metadata: { code: "host_claude_failed" },
			};
			continue;
		}
		const mapped = mapClaudeJsonEvent(event);
		if (mapped.sessionId) cliSessionId = mapped.sessionId;
		for (const chunk of mapped.chunks) yield chunk;
		if (mapped.done) {
			closed = true;
			yield doneChunk(startedAt, {
				...mapped.done.metadata,
				resume: resumeFor(cliSessionId ?? mapped.sessionId),
			});
		}
	}
	return { closed, sessionId: cliSessionId };
}

export const hostProvider: ComputeProvider = {
	id: "host",
	async *runTurn(request: TurnRequest): AsyncIterable<StreamChunk> {
		const startedAt = Date.now();
		const targetRepo = resolveTargetRepo(request);
		if (!targetRepo.ok) {
			yield failureChunk({
				code: "invalid_repo",
				message: targetRepo.error,
			});
			yield abortedDone(startedAt);
			return;
		}

		const workspaceDir = resolveHostWorkspaceDir(request.sessionId);
		if (typeof workspaceDir !== "string") {
			yield failureChunk(workspaceDir);
			yield abortedDone(startedAt);
			return;
		}

		const claudeBin = await resolveClaudeBinary();
		if (typeof claudeBin !== "string") {
			yield failureChunk(claudeBin);
			yield abortedDone(startedAt);
			return;
		}

		yield { type: "status", content: "Preparing host workspace" };
		const workspaceError = await ensureWorkspace(
			workspaceDir,
			targetRepo.repo,
			request.signal,
		);
		if (workspaceError) {
			yield failureChunk(workspaceError);
			yield abortedDone(startedAt);
			return;
		}

		const args = buildClaudeArgs(request);
		const env = curatedClaudeEnv();
		const prompt = buildHostPrompt(
			request,
			targetRepo.repo.fullName,
			workspaceDir,
		);
		let child: ChildProcessWithoutNullStreams | undefined;
		let settled = false;
		let stderr = "";
		const onAbort = () => {
			if (child) terminateChild(child);
		};
		try {
			yield { type: "status", content: "Starting local Claude Code" };
			child = spawn(claudeBin, args, {
				cwd: workspaceDir,
				env,
				stdio: ["pipe", "pipe", "pipe"],
			});
			child.stderr.setEncoding("utf8");
			child.stderr.on("data", (chunk: string) => {
				stderr += chunk;
			});
			request.signal?.addEventListener("abort", onAbort, { once: true });
			child.stdin.end(prompt);
			const exitPromise = waitForExit(child).finally(() => {
				settled = true;
			});
			const stream = streamClaudeProcess(child, startedAt);
			let streamResult: { closed: boolean; sessionId?: string } = {
				closed: false,
			};
			for (;;) {
				const next = await stream.next();
				if (next.done) {
					streamResult = next.value;
					break;
				}
				yield next.value;
			}
			const exit = await exitPromise;
			if (request.signal?.aborted) {
				if (!streamResult.closed) {
					yield { type: "error", content: HOST_ABORT_MESSAGE };
					yield abortedDone(startedAt);
				}
				return;
			}
			if (exit.code !== 0) {
				if (!streamResult.closed) {
					yield failureChunk({
						code: "host_claude_failed",
						message: `claude exited with ${exit.signal ?? `code ${exit.code ?? "unknown"}`}${stderr ? `: ${capStderr(stderr)}` : ""}`,
					});
					yield abortedDone(startedAt);
				}
				return;
			}
			if (!streamResult.closed) {
				yield doneChunk(startedAt, {
					resume: resumeFor(streamResult.sessionId),
				});
			}
		} finally {
			request.signal?.removeEventListener("abort", onAbort);
			if (child && !settled) terminateChild(child);
		}
	},
};
