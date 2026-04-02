import { Sandbox, Snapshot } from "@vercel/sandbox";
import ms from "ms";
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
	// Check existing snapshots for a reusable base
	const result = await Snapshot.list(getCredentials());
	const existing = result.json.snapshots.find(
		(s: { id: string; status: string }) => s.status === "created",
	);
	if (existing) return existing.id;

	// Create fresh base: node22 + Claude Code CLI
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

	const snapshot = await sandbox.snapshot({ expiration: ms("30d") });
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
			env: {
				ANTHROPIC_API_KEY: stripQuotes(apiKey),
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

			// Write prompt, message, and a runner script to files.
			// The runner script avoids shell injection by reading from files
			// and passing via env var (not shell interpolation).
			// On first run, --session-id creates a named session that persists to disk.
			// On restore (claude-resume.flag exists), --resume loads the prior session,
			// giving the agent full memory of its previous reasoning and tool calls.
			// Session args (--session-id / --resume) are written but disabled until
			// the base snapshot's Claude Code CLI version is verified to support them.
			// The session-id file and resume flag are still written to the sandbox
			// so they'll be ready when re-enabled.
			const runnerScript = `#!/bin/bash
PROMPT=$(cat /vercel/sandbox/system-prompt.txt)
cat /vercel/sandbox/message.txt | claude -p --system-prompt "$PROMPT" --allowedTools ${tools}
`;

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
					content: Buffer.from(runnerScript),
				},
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
			env: {
				ANTHROPIC_API_KEY: stripQuotes(process.env.ANTHROPIC_API_KEY ?? ""),
			},
			networkPolicy: { allow: ALLOWED_DOMAINS },
		});

		const instanceId = sandbox.sandboxId;
		activeSandboxes.set(instanceId, sandbox);
		return { instanceId, status: "ready" };
	}
}
