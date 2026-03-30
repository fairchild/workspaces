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

/** Module-level cache for base snapshot ID */
let _baseSnapshotId: string | undefined;

/**
 * Get or create a base snapshot with Claude Code CLI pre-installed.
 * Cached in-memory and reused across sessions for fast warm-start.
 */
async function getOrCreateBaseSnapshot(): Promise<string> {
	if (_baseSnapshotId) return _baseSnapshotId;

	// Check existing snapshots for a reusable base
	const result = await Snapshot.list(getCredentials());
	const existing = result.json.snapshots.find(
		(s: { id: string; status: string }) => s.status === "created",
	);
	if (existing) {
		const id = existing.id;
		_baseSnapshotId = id;
		return id;
	}

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

	const snapshot = await sandbox.snapshot({
		expiration: ms("30d"),
	});

	const id = snapshot.snapshotId;
	_baseSnapshotId = id;
	return id;
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
		const baseSnapshotId = await getOrCreateBaseSnapshot();

		const sandbox = await Sandbox.create({
			...getCredentials(),
			source: { type: "snapshot", snapshotId: baseSnapshotId },
			timeout: request.readOnly ? ms("10m") : ms("30m"),
			resources: { vcpus: 2 },
			env: {
				ANTHROPIC_API_KEY: stripQuotes(process.env.ANTHROPIC_API_KEY ?? ""),
				...request.envVars,
			},
			networkPolicy: { allow: ALLOWED_DOMAINS },
		});

		// Clone the target repo
		const cloneArgs = ["clone", "--depth", "1"];
		if (request.branch) {
			cloneArgs.push("--branch", request.branch);
		}
		cloneArgs.push(request.cloneUrl, "/vercel/sandbox/repo");
		await sandbox.runCommand("git", cloneArgs);

		// Start Claude Code as a detached process.
		// Claude CLI uses: echo "msg" | claude -p --system-prompt "..." --allowedTools ...
		// Output goes to a JSONL file for streaming.
		const tools =
			request.tools === "conversational" ? CONVERSATIONAL_TOOLS : FULL_TOOLS;

		const escapedPrompt = request.systemPrompt.replace(/"/g, '\\"');
		const escapedMessage = request.message.replace(/"/g, '\\"');

		await sandbox.runCommand({
			cmd: "bash",
			args: [
				"-c",
				`echo "${escapedMessage}" | claude -p --system-prompt "${escapedPrompt}" --allowedTools ${tools} > /vercel/sandbox/agent-output.txt 2>&1`,
			],
			cwd: "/vercel/sandbox/repo",
			detached: true,
		});

		const instanceId = sandbox.sandboxId;
		activeSandboxes.set(instanceId, sandbox);

		return { instanceId, status: "ready" };
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) {
			yield { type: "error", content: "Sandbox not found" };
			return;
		}

		// Read the stream-json output from Claude's stdout
		// The detached process writes to stdout which we capture via readFile
		// For now, poll the output file until the process completes
		const outputPath = "/vercel/sandbox/agent-output.jsonl";

		// Write a wrapper script that captures claude output to a file
		// This is needed because detached command stdout isn't directly streamable
		// TODO: Improve with direct stdout piping when @vercel/sandbox supports it
		let lastOffset = 0;
		let done = false;

		while (!done) {
			try {
				const buffer = await sandbox.readFileToBuffer({
					path: outputPath,
				});
				if (!buffer) continue;
				const content = buffer.toString("utf-8");
				const newContent = content.slice(lastOffset);
				lastOffset = content.length;

				if (newContent) {
					for (const line of newContent.split("\n").filter(Boolean)) {
						try {
							const parsed = JSON.parse(line);
							yield {
								type: parsed.type ?? "text",
								content: parsed.content ?? parsed.text ?? line,
								metadata: parsed,
							};
							if (parsed.type === "result") {
								done = true;
							}
						} catch {
							yield { type: "text", content: line };
						}
					}
				}
			} catch {
				// File may not exist yet, or process still starting
			}

			if (!done) {
				await new Promise((r) => setTimeout(r, 500));
			}
		}

		yield { type: "done", content: "" };
	}

	async sendMessage(instanceId: string, message: string): Promise<void> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) throw new Error(`Sandbox ${instanceId} not found`);

		// Write message to a file and run claude with --resume
		await sandbox.writeFiles([
			{
				path: "/vercel/sandbox/next-message.txt",
				content: Buffer.from(message),
			},
		]);

		await sandbox.runCommand({
			cmd: "claude",
			args: [
				"--print",
				"--output-format",
				"stream-json",
				"--resume",
				"--message",
				message,
			],
			cwd: "/vercel/sandbox/repo",
			detached: true,
		});
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
