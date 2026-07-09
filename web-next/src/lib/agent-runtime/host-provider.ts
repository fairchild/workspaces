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
import type {
	ComputeProvider,
	SessionResumeHandle,
	TurnRepo,
	TurnRequest,
} from "./provider";
import type { StreamChunk } from "./stream-chunk";
import {
	configReceiptChunk,
	hasConfigReceipt,
	loadRuntimeConfig,
} from "./config-files";
import {
	canonicalToolName,
	errorText,
	resolveTargetRepo,
	toolResultContent,
} from "./vercel-provider";

const HOST_WORKSPACE_ROOT_ENV = "WEB_NEXT_HOST_WORKSPACE_ROOT";
const HOST_CLAUDE_BIN_ENV = "WEB_NEXT_HOST_CLAUDE_BIN";
const HOST_TURN_TIMEOUT_ENV = "WEB_NEXT_HOST_TURN_TIMEOUT_MS";
const HOST_ABORT_MESSAGE = "Turn stopped.";
const KILL_GRACE_MS = 5_000;
const EXIT_AFTER_STDOUT_CLOSE_TIMEOUT_MS = 10_000;
const DEFAULT_HOST_TURN_TIMEOUT_MS = 900_000;
const STDERR_RETAIN_BYTES = 8 * 1024;
const STDOUT_LINE_RETAIN_BYTES = 1024 * 1024;

export const HOST_ALLOWED_TOOLS = [
	"Read",
	"LS",
	"Glob",
	"Grep",
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
	"ANTHROPIC_BASE_URL",
	"ANTHROPIC_CUSTOM_HEADERS",
	"CLAUDE_CODE_OAUTH_TOKEN",
	"CLAUDE_CODE_API_KEY_HELPER",
	"CLAUDE_CONFIG_DIR",
]);

/*
 * API-key credentials are NOT curated through by default: the server sets
 * ANTHROPIC_API_KEY for the vercel provider, and letting it reach the local
 * claude binary silently flips host turns from subscription billing to
 * API-key billing — the opposite of this provider's purpose (see
 * docs/decisions/host-compute-daily-driver.md). The binary's own login
 * (keychain via HOME) or CLAUDE_CODE_OAUTH_TOKEN are the sanctioned paths.
 * Set WEB_NEXT_HOST_PASS_API_KEY=1 to opt in deliberately.
 */
const API_KEY_ENV_KEYS = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] as const;
const HOST_PASS_API_KEY_ENV = "WEB_NEXT_HOST_PASS_API_KEY";

type ProviderFailureCode =
	| "host_workspace_root_unset"
	| "invalid_repo"
	| "invalid_session_id"
	| "host_claude_missing"
	| "host_workspace_setup_failed"
	| "host_turn_timeout"
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

interface RetainedText {
	text: string;
	truncated: boolean;
}

interface TurnLifetime {
	signal: AbortSignal;
	timedOut: () => boolean;
	dispose: () => void;
}

interface StreamResult {
	closed: boolean;
	sessionId?: string;
	sawError: boolean;
	sawAbortedDone: boolean;
}

interface ClaudeAttemptResult {
	failed: boolean;
	assistantContent: boolean;
	closed: boolean;
	aborted: boolean;
	timedOut: boolean;
	exitTimedOut: boolean;
	sessionId?: string;
}

interface BufferedAttemptResult extends ClaudeAttemptResult {
	bufferedChunks: StreamChunk[];
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

function abortedDone(
	startedAt: number,
	metadata: Partial<HostDoneMeta> = {},
): StreamChunk {
	return doneChunk(startedAt, { aborted: true, ...metadata });
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
	if (source[HOST_PASS_API_KEY_ENV] === "1") {
		for (const key of API_KEY_ENV_KEYS) {
			const value = source[key];
			if (value !== undefined) env[key] = value;
		}
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

function resolveHostTurnTimeoutMs(
	env: NodeJS.ProcessEnv = process.env,
): number {
	const raw = env[HOST_TURN_TIMEOUT_ENV]?.trim();
	if (!raw) return DEFAULT_HOST_TURN_TIMEOUT_MS;
	const parsed = Number.parseInt(raw, 10);
	return Number.isFinite(parsed) && parsed > 0
		? parsed
		: DEFAULT_HOST_TURN_TIMEOUT_MS;
}

function createTurnLifetime(
	source: AbortSignal | undefined,
	timeoutMs: number,
): TurnLifetime {
	const controller = new AbortController();
	let timedOut = false;
	const abortFromSource = () => {
		if (!controller.signal.aborted) controller.abort(source?.reason);
	};
	const timeout = setTimeout(() => {
		timedOut = true;
		if (!controller.signal.aborted) controller.abort(new Error("host turn timed out"));
	}, timeoutMs);
	timeout.unref();
	if (source) {
		if (source.aborted) abortFromSource();
		else source.addEventListener("abort", abortFromSource, { once: true });
	}
	return {
		signal: controller.signal,
		timedOut: () => timedOut,
		dispose: () => {
			clearTimeout(timeout);
			source?.removeEventListener("abort", abortFromSource);
		},
	};
}

function timeoutFailure(timeoutMs: number): HostFailure {
	return {
		code: "host_turn_timeout",
		message: `host Claude turn timed out after ${timeoutMs}ms`,
	};
}

function appendRetainedText(
	retained: RetainedText,
	chunk: string,
	limitBytes: number,
): RetainedText {
	if (!chunk) return retained;
	const next = retained.text + chunk;
	if (Buffer.byteLength(next, "utf8") <= limitBytes) {
		return { text: next, truncated: retained.truncated };
	}
	const bytes = Buffer.from(next, "utf8");
	return {
		text: bytes.subarray(Math.max(0, bytes.length - limitBytes)).toString("utf8"),
		truncated: true,
	};
}

function formatRetainedStderr(stderr: RetainedText): string {
	const text = stderr.text.trim();
	if (!text) return "";
	if (!stderr.truncated) return text;
	return `[stderr truncated to last ${STDERR_RETAIN_BYTES} bytes]\n${text}`;
}

function assistantContentChunk(chunk: StreamChunk): boolean {
	return (
		chunk.type === "text" ||
		chunk.type === "reasoning" ||
		chunk.type === "tool_use" ||
		chunk.type === "tool_result"
	);
}

function doneWasAborted(chunk: StreamChunk): boolean {
	return chunk.type === "done" && chunk.metadata?.aborted === true;
}

function metadataWithResumeClear(
	clearResumeOnFailure: boolean,
): Partial<HostDoneMeta> {
	return clearResumeOnFailure ? { resume: null } : {};
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
		detached: true,
		stdio: ["ignore", "ignore", "pipe"],
	});
	let stderr: RetainedText = { text: "", truncated: false };
	child.stderr?.setEncoding("utf8");
	child.stderr?.on("data", (chunk: string) => {
		stderr = appendRetainedText(stderr, chunk, STDERR_RETAIN_BYTES);
	});
	const stop = () => terminateChild(child);
	options.signal?.addEventListener("abort", stop, { once: true });
	try {
		const exit = await waitForExitRespectingAbort(
			child,
			waitForExit(child),
			options.signal,
		);
		return exit.code === 0
			? { ok: true }
			: { ok: false, stderr: formatRetainedStderr(stderr), code: exit.code };
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

const workspaceSetupBySession = new Map<string, Promise<HostFailure | null>>();

async function ensureWorkspaceOnce(
	sessionId: string,
	workspaceDir: string,
	repo: TurnRepo,
	signal?: AbortSignal,
): Promise<HostFailure | null> {
	let setup = workspaceSetupBySession.get(sessionId);
	if (!setup) {
		setup = ensureWorkspace(workspaceDir, repo, signal).finally(() => {
			if (workspaceSetupBySession.get(sessionId) === setup) {
				workspaceSetupBySession.delete(sessionId);
			}
		});
		workspaceSetupBySession.set(sessionId, setup);
	}
	return waitForPromiseRespectingAbort(setup, signal);
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
	appendSystemPrompt?: string,
): string[] {
	const args = [
		"-p",
		"--output-format",
		"stream-json",
		"--verbose",
		// Host v1 is intentionally configless: --safe-mode disables user/project
		// customizations (settings-driven hooks, MCP, agents, plugins, CLAUDE.md,
		// etc.) while keeping normal auth/model/tool permission behavior. Config
		// parity belongs to #985; keep the explicit tool allowlist as defense in
		// depth until the approval/config protocol exists.
		"--safe-mode",
		"--strict-mcp-config",
		"--tools",
		HOST_ALLOWED_TOOLS.join(","),
		"--allowedTools",
		HOST_ALLOWED_TOOLS.join(","),
		"--permission-mode",
		"dontAsk",
	];
	if (appendSystemPrompt?.trim()) {
		args.push("--append-system-prompt", appendSystemPrompt);
	}
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

function waitForExitWithTimeout(
	exit: Promise<ExitStatus>,
	timeoutMs: number,
): Promise<ExitStatus | null> {
	return new Promise((resolve, reject) => {
		const timeout = setTimeout(() => resolve(null), timeoutMs);
		timeout.unref();
		exit.then(
			(value) => {
				clearTimeout(timeout);
				resolve(value);
			},
			(error) => {
				clearTimeout(timeout);
				reject(error);
			},
		);
	});
}

async function waitForExitRespectingAbort(
	child: ChildProcess,
	exit: Promise<ExitStatus>,
	signal?: AbortSignal,
): Promise<ExitStatus> {
	if (!signal) return exit;
	if (signal.aborted) {
		terminateChild(child);
		return (
			(await waitForExitWithTimeout(exit, KILL_GRACE_MS + 1_000)) ?? {
				code: null,
				signal: "SIGKILL",
			}
		);
	}
	let onAbort: () => void = () => {};
	const aborted = new Promise<"aborted">((resolve) => {
		onAbort = () => resolve("aborted");
		signal.addEventListener("abort", onAbort, { once: true });
	});
	try {
		const result = await Promise.race([exit, aborted]);
		if (result !== "aborted") return result;
		terminateChild(child);
		return (
			(await waitForExitWithTimeout(exit, KILL_GRACE_MS + 1_000)) ?? {
				code: null,
				signal: "SIGKILL",
			}
		);
	} finally {
		signal.removeEventListener("abort", onAbort);
	}
}

function waitForPromiseRespectingAbort<T>(
	promise: Promise<T>,
	signal?: AbortSignal,
): Promise<T> {
	if (!signal) return promise;
	if (signal.aborted) return Promise.reject(signal.reason ?? new Error("aborted"));
	let onAbort: () => void = () => {};
	const aborted = new Promise<never>((_, reject) => {
		onAbort = () => reject(signal.reason ?? new Error("aborted"));
		signal.addEventListener("abort", onAbort, { once: true });
	});
	return Promise.race([promise, aborted]).finally(() => {
		signal.removeEventListener("abort", onAbort);
	});
}

function signalChild(child: ChildProcess, signal: NodeJS.Signals): void {
	if (child.exitCode !== null || child.signalCode !== null) return;
	const pid = child.pid;
	if (pid) {
		try {
			process.kill(-pid, signal);
			return;
		} catch {
			// Fall back to the direct child below; older/failed launches may not
			// have a process group even though the normal claude path is detached.
		}
	}
	try {
		child.kill(signal);
	} catch {
		// Nothing else to do; the bounded exit wait will synthesize failure.
	}
}

function terminateChild(child: ChildProcess): void {
	if (child.exitCode !== null || child.signalCode !== null) return;
	signalChild(child, "SIGTERM");
	setTimeout(() => {
		if (child.exitCode === null && child.signalCode === null) {
			signalChild(child, "SIGKILL");
		}
	}, KILL_GRACE_MS).unref();
}

async function* boundedStdoutLines(
	child: ChildProcessWithoutNullStreams,
	signal: AbortSignal,
): AsyncGenerator<
	{ ok: true; line: string } | { ok: false; error: StreamChunk },
	void,
	void
> {
	let buffer = "";
	let bufferBytes = 0;
	let droppingLongLine = false;
	let reportedLongLine = false;
	const onAbort = () => {
		child.stdout.destroy();
	};
	signal.addEventListener("abort", onAbort, { once: true });
	child.stdout.setEncoding("utf8");
	try {
		for await (const rawChunk of child.stdout) {
			let chunk = String(rawChunk);
			while (chunk.length > 0) {
				const newlineIndex = chunk.indexOf("\n");
				const segment =
					newlineIndex === -1 ? chunk : chunk.slice(0, newlineIndex);
				chunk = newlineIndex === -1 ? "" : chunk.slice(newlineIndex + 1);
				if (!droppingLongLine) {
					const segmentBytes = Buffer.byteLength(segment, "utf8");
					if (bufferBytes + segmentBytes > STDOUT_LINE_RETAIN_BYTES) {
						buffer = "";
						bufferBytes = 0;
						droppingLongLine = true;
						if (!reportedLongLine) {
							reportedLongLine = true;
							yield {
								ok: false,
								error: {
									type: "error",
									content: `claude stream-json line exceeded ${STDOUT_LINE_RETAIN_BYTES} bytes and was dropped`,
									metadata: { code: "host_claude_failed" },
								},
							};
						}
					} else {
						buffer += segment;
						bufferBytes += segmentBytes;
					}
				}
				if (newlineIndex !== -1) {
					if (!droppingLongLine) {
						const line = buffer.endsWith("\r")
							? buffer.slice(0, -1)
							: buffer;
						yield { ok: true, line };
					}
					buffer = "";
					bufferBytes = 0;
					droppingLongLine = false;
					reportedLongLine = false;
				}
			}
		}
		if (buffer && !droppingLongLine) {
			yield { ok: true, line: buffer.endsWith("\r") ? buffer.slice(0, -1) : buffer };
		}
	} finally {
		signal.removeEventListener("abort", onAbort);
	}
}

async function* streamClaudeProcess(
	child: ChildProcessWithoutNullStreams,
	startedAt: number,
	signal: AbortSignal,
	clearResumeOnFailure: boolean,
): AsyncGenerator<StreamChunk, StreamResult, void> {
	let cliSessionId: string | undefined;
	let closed = false;
	let sawError = false;
	let sawAbortedDone = false;
	for await (const item of boundedStdoutLines(child, signal)) {
		if (!item.ok) {
			sawError = true;
			yield item.error;
			continue;
		}
		const line = item.line.trim();
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
			sawError = true;
			continue;
		}
		const mapped = mapClaudeJsonEvent(event);
		if (mapped.sessionId) cliSessionId = mapped.sessionId;
		for (const chunk of mapped.chunks) {
			if (chunk.type === "error") sawError = true;
			yield chunk;
		}
		if (mapped.done) {
			closed = true;
			const metadata = {
				...mapped.done.metadata,
				resume:
					mapped.done.metadata.aborted && clearResumeOnFailure
						? null
						: resumeFor(cliSessionId ?? mapped.sessionId),
			};
			if (metadata.aborted) sawAbortedDone = true;
			yield doneChunk(startedAt, metadata);
		}
	}
	return { closed, sessionId: cliSessionId, sawError, sawAbortedDone };
}

interface ClaudeAttemptOptions {
	claudeBin: string;
	args: string[];
	prompt: string;
	workspaceDir: string;
	env: NodeJS.ProcessEnv;
	startedAt: number;
	signal: AbortSignal;
	timedOut: () => boolean;
	timeoutMs: number;
	clearResumeOnFailure: boolean;
}

function failureDoneMetadata(
	clearResumeOnFailure: boolean,
): Partial<HostDoneMeta> {
	return metadataWithResumeClear(clearResumeOnFailure);
}

async function* executeClaudeAttempt({
	claudeBin,
	args,
	prompt,
	workspaceDir,
	env,
	startedAt,
	signal,
	timedOut,
	timeoutMs,
	clearResumeOnFailure,
}: ClaudeAttemptOptions): AsyncGenerator<StreamChunk, ClaudeAttemptResult, void> {
	let child: ChildProcessWithoutNullStreams | undefined;
	let settled = false;
	let exitPromise: Promise<ExitStatus> | undefined;
	let assistantContent = false;
	let stderr: RetainedText = { text: "", truncated: false };
	const failureMeta = failureDoneMetadata(clearResumeOnFailure);
	const baseResult = (): ClaudeAttemptResult => ({
		failed: true,
		assistantContent,
		closed: false,
		aborted: signal.aborted && !timedOut(),
		timedOut: timedOut(),
		exitTimedOut: false,
	});
	const stop = () => {
		if (!child) return;
		terminateChild(child);
		child.stdin.destroy();
		child.stdout.destroy();
		child.stderr.destroy();
	};

	if (signal.aborted) {
		if (timedOut()) {
			yield failureChunk(timeoutFailure(timeoutMs));
		} else {
			yield { type: "error", content: HOST_ABORT_MESSAGE };
		}
		yield abortedDone(startedAt, failureMeta);
		return baseResult();
	}

	try {
		child = spawn(claudeBin, args, {
			cwd: workspaceDir,
			env,
			detached: true,
			stdio: ["pipe", "pipe", "pipe"],
		});
		exitPromise = waitForExit(child).finally(() => {
			settled = true;
		});
		child.stderr.setEncoding("utf8");
		child.stderr.on("data", (chunk: string) => {
			stderr = appendRetainedText(stderr, chunk, STDERR_RETAIN_BYTES);
		});
		signal.addEventListener("abort", stop, { once: true });
		child.stdin.end(prompt);

		const stream = streamClaudeProcess(
			child,
			startedAt,
			signal,
			clearResumeOnFailure,
		);
		let streamResult: StreamResult = {
			closed: false,
			sawError: false,
			sawAbortedDone: false,
		};
		for (;;) {
			const next = await stream.next();
			if (next.done) {
				streamResult = next.value;
				break;
			}
			if (assistantContentChunk(next.value)) assistantContent = true;
			yield next.value;
		}

		let exitTimedOut = false;
		let exit = await waitForExitWithTimeout(
			exitPromise,
			EXIT_AFTER_STDOUT_CLOSE_TIMEOUT_MS,
		);
		if (!exit) {
			exitTimedOut = true;
			terminateChild(child);
			exit = await waitForExitWithTimeout(exitPromise, KILL_GRACE_MS + 1_000);
		}

		const attemptResult = (
			overrides: Partial<ClaudeAttemptResult> = {},
		): ClaudeAttemptResult => ({
			failed: true,
			assistantContent,
			closed: streamResult.closed,
			aborted: signal.aborted && !timedOut(),
			timedOut: timedOut(),
			exitTimedOut,
			sessionId: streamResult.sessionId,
			...overrides,
		});

		if (timedOut()) {
			if (!streamResult.closed) {
				yield failureChunk(timeoutFailure(timeoutMs));
				yield abortedDone(startedAt, failureMeta);
			}
			return attemptResult({ timedOut: true });
		}

		if (signal.aborted) {
			if (!streamResult.closed) {
				yield { type: "error", content: HOST_ABORT_MESSAGE };
				yield abortedDone(startedAt, failureMeta);
			}
			return attemptResult({ aborted: true });
		}

		if (exitTimedOut) {
			if (!streamResult.closed) {
				yield failureChunk({
					code: "host_claude_failed",
					message: `claude stdout closed but the process did not exit within ${EXIT_AFTER_STDOUT_CLOSE_TIMEOUT_MS}ms; killed`,
				});
				yield abortedDone(startedAt, failureMeta);
			}
			return attemptResult({ exitTimedOut: true });
		}

		if (!exit || exit.code !== 0) {
			if (!streamResult.closed) {
				const detail = formatRetainedStderr(stderr);
				yield failureChunk({
					code: "host_claude_failed",
					message: `claude exited with ${exit?.signal ?? `code ${exit?.code ?? "unknown"}`}${detail ? `: ${detail}` : ""}`,
				});
				yield abortedDone(startedAt, failureMeta);
			}
			return attemptResult();
		}

		if (!streamResult.closed) {
			const done = doneChunk(startedAt, {
				resume: resumeFor(streamResult.sessionId),
			});
			yield done;
			streamResult = {
				...streamResult,
				closed: true,
				sawAbortedDone: doneWasAborted(done),
			};
		}

		return attemptResult({
			failed: streamResult.sawError || streamResult.sawAbortedDone,
			closed: streamResult.closed,
		});
	} catch (error) {
		if (timedOut()) {
			yield failureChunk(timeoutFailure(timeoutMs));
		} else if (signal.aborted) {
			yield { type: "error", content: HOST_ABORT_MESSAGE };
		} else {
			yield failureChunk({
				code: "host_claude_failed",
				message: errorText(error),
			});
		}
		yield abortedDone(startedAt, failureMeta);
		if (child && exitPromise && signal.aborted) {
			terminateChild(child);
			await waitForExitWithTimeout(exitPromise, KILL_GRACE_MS + 1_000);
		}
		return baseResult();
	} finally {
		signal.removeEventListener("abort", stop);
		if (child && !settled) terminateChild(child);
	}
}

async function* bufferUntilAssistantContent(
	attempt: AsyncGenerator<StreamChunk, ClaudeAttemptResult, void>,
): AsyncGenerator<StreamChunk, BufferedAttemptResult, void> {
	const bufferedChunks: StreamChunk[] = [];
	let emitted = false;
	for (;;) {
		const next = await attempt.next();
		if (next.done) {
			return {
				...next.value,
				assistantContent: next.value.assistantContent || emitted,
				bufferedChunks: emitted ? [] : bufferedChunks,
			};
		}
		const chunk = next.value;
		if (!emitted && assistantContentChunk(chunk)) {
			emitted = true;
			for (const buffered of bufferedChunks) yield buffered;
			bufferedChunks.length = 0;
		}
		if (emitted) {
			yield chunk;
		} else {
			bufferedChunks.push(chunk);
		}
	}
}

function shouldFallbackFromResume(
	request: TurnRequest,
	result: BufferedAttemptResult,
): boolean {
	return Boolean(
		request.resume &&
			result.failed &&
			!result.assistantContent &&
			!result.aborted &&
			!result.timedOut,
	);
}

export const hostProvider: ComputeProvider = {
	id: "host",
	async *runTurn(request: TurnRequest): AsyncIterable<StreamChunk> {
		const startedAt = Date.now();
		const config = await loadRuntimeConfig();
		if (hasConfigReceipt(config.receipt)) yield configReceiptChunk(config.receipt);
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

		const timeoutMs = resolveHostTurnTimeoutMs();
		const lifetime = createTurnLifetime(request.signal, timeoutMs);
		try {
			yield { type: "status", content: "Preparing host workspace" };
			let workspaceError: HostFailure | null;
			try {
				workspaceError = await ensureWorkspaceOnce(
					request.sessionId,
					workspaceDir,
					targetRepo.repo,
					lifetime.signal,
				);
			} catch (error) {
				if (lifetime.timedOut()) {
					workspaceError = timeoutFailure(timeoutMs);
				} else if (lifetime.signal.aborted) {
					yield { type: "error", content: HOST_ABORT_MESSAGE };
					yield abortedDone(startedAt);
					return;
				} else {
					workspaceError = {
						code: "host_workspace_setup_failed",
						message: `host workspace setup failed: ${errorText(error)}`,
					};
				}
			}
			if (workspaceError) {
				yield failureChunk(workspaceError);
				yield abortedDone(startedAt);
				return;
			}
			if (lifetime.signal.aborted) {
				if (lifetime.timedOut()) yield failureChunk(timeoutFailure(timeoutMs));
				else yield { type: "error", content: HOST_ABORT_MESSAGE };
				yield abortedDone(startedAt);
				return;
			}

			const env = curatedClaudeEnv();
			const runAttempt = (
				attemptRequest: TurnRequest,
				clearResumeOnFailure: boolean,
			) =>
				bufferUntilAssistantContent(
					executeClaudeAttempt({
						claudeBin,
						args: buildClaudeArgs(attemptRequest, config.prompt),
						prompt: buildHostPrompt(
							attemptRequest,
							targetRepo.repo.fullName,
							workspaceDir,
						),
						workspaceDir,
						env,
						startedAt,
						signal: lifetime.signal,
						timedOut: lifetime.timedOut,
						timeoutMs,
						clearResumeOnFailure,
					}),
				);

			yield { type: "status", content: "Starting local Claude Code" };
			let attempt = runAttempt(request, false);
			let result = yield* attempt;
			if (shouldFallbackFromResume(request, result)) {
				yield {
					type: "status",
					content: "Previous local Claude session failed — starting fresh",
				};
				const freshRequest: TurnRequest = { ...request, resume: undefined };
				attempt = runAttempt(freshRequest, true);
				result = yield* attempt;
			}

			for (const chunk of result.bufferedChunks) yield chunk;
		} finally {
			lifetime.dispose();
		}
	},
};
