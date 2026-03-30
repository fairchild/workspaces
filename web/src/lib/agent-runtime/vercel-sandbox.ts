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
/** Tool set per sandbox, set during createSandbox for use in streamOutput. */
const activeSandboxTools = new Map<string, string>();

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
		activeSandboxes.set(instanceId, sandbox);
		activeSandboxTools.set(instanceId, tools);

		// Write prompt, message, and a runner script to files.
		// The runner script avoids shell injection by reading from files
		// and passing via env var (not shell interpolation).
		const runnerScript = `#!/bin/bash
PROMPT=$(cat /vercel/sandbox/system-prompt.txt)
cat /vercel/sandbox/message.txt | claude -p --system-prompt "$PROMPT" --allowedTools ${tools}
`;

		await sandbox.writeFiles([
			{
				path: "/vercel/sandbox/system-prompt.txt",
				content: Buffer.from(request.systemPrompt),
			},
			{
				path: "/vercel/sandbox/message.txt",
				content: Buffer.from(request.message),
			},
			{
				path: "/vercel/sandbox/run-agent.sh",
				content: Buffer.from(runnerScript),
			},
		]);

		return { instanceId, status: "ready" };
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) {
			yield { type: "error", content: "Sandbox not found" };
			return;
		}

		// Run claude synchronously — blocks until response is complete.
		// The SSE route has a 5-min timeout which is sufficient for conversational queries.
		const result = await sandbox.runCommand({
			cmd: "bash",
			args: ["/vercel/sandbox/run-agent.sh"],
			cwd: "/vercel/sandbox/repo",
		});

		const stdout = await result.stdout();
		const stderr = await result.stderr();

		if (result.exitCode !== 0) {
			yield {
				type: "error",
				content: stderr.trim() || `Claude exited with code ${result.exitCode}`,
			};
			return;
		}

		if (stdout.trim()) {
			yield { type: "text", content: stdout.trim() };
		}

		yield { type: "done", content: "" };
	}

	async sendMessage(instanceId: string, message: string): Promise<void> {
		const sandbox = activeSandboxes.get(instanceId);
		if (!sandbox) throw new Error(`Sandbox ${instanceId} not found`);

		// Write new message for the next streamOutput call
		await sandbox.writeFiles([
			{
				path: "/vercel/sandbox/message.txt",
				content: Buffer.from(message),
			},
		]);
	}

	async destroySandbox(instanceId: string): Promise<void> {
		const sandbox = activeSandboxes.get(instanceId);
		if (sandbox) {
			await sandbox.stop();
			activeSandboxes.delete(instanceId);
			activeSandboxTools.delete(instanceId);
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
