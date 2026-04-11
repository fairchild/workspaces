#!/usr/bin/env -S npx tsx
export {};
/**
 * Simulates GitHub webhook events for local development.
 *
 * Usage:
 *   npx tsx scripts/simulate-webhooks.ts              # send 5 random events
 *   npx tsx scripts/simulate-webhooks.ts --count 20   # send 20 events
 *   npx tsx scripts/simulate-webhooks.ts --stream      # send 1 event every 5s
 *   npx tsx scripts/simulate-webhooks.ts --url https://spaces.cloudcompute.com  # target production
 */

const BASE_URL = process.argv.includes("--url")
	? process.argv[process.argv.indexOf("--url") + 1]
	: "http://localhost:3000";

const count = process.argv.includes("--count")
	? Number(process.argv[process.argv.indexOf("--count") + 1])
	: 5;

const stream = process.argv.includes("--stream");

const REPO = "fairchild/workspaces";

interface EventTemplate {
	type: string;
	payload: Record<string, unknown>;
}

const templates: EventTemplate[] = [
	{
		type: "pull_request",
		payload: {
			action: "opened",
			pull_request: {
				number: randomInt(200, 250),
				title: pick([
					"feat: add workspace templates",
					"fix: terminal focus lost on split",
					"refactor: extract sidebar into composable",
					"chore: update dependencies",
					"feat(web): agent schedule view",
				]),
			},
			repository: { full_name: REPO },
		},
	},
	{
		type: "pull_request",
		payload: {
			action: "closed",
			pull_request: {
				number: randomInt(180, 210),
				title: pick([
					"fix: resolve merge conflict in pipeline",
					"feat: notification catch-up protocol",
					"chore: bump GhosttyKit pin",
				]),
				merged: true,
			},
			repository: { full_name: REPO },
		},
	},
	{
		type: "push",
		payload: {
			ref: pick([
				"refs/heads/main",
				"refs/heads/webspaces",
				"refs/heads/feat/agent-schedule",
			]),
			commits: Array.from({ length: randomInt(1, 5) }, () => ({
				message: pick([
					"fix lint",
					"update types",
					"add tests",
					"refactor cache",
					"bump version",
				]),
			})),
			repository: { full_name: REPO },
		},
	},
	{
		type: "issues",
		payload: {
			action: pick(["opened", "labeled", "closed"]),
			issue: {
				number: randomInt(100, 220),
				title: pick([
					"Agent schedule not respecting timezone",
					"Pipeline kanban drag-and-drop",
					"Add workspace search",
					"Terminal splits not persisting",
				]),
				labels: [
					{
						name: pick([
							"agent:ready",
							"agent:claimed",
							"agent:review",
							"enhancement",
							"bug",
						]),
					},
				],
			},
			repository: { full_name: REPO },
		},
	},
	{
		type: "discussion",
		payload: {
			action: "created",
			discussion: {
				number: randomInt(50, 80),
				title: pick([
					"[idea] Quick workspace switcher (Cmd+P)",
					"[task] Implement notification catch-up",
					"[decision] Pipeline column ordering",
					"[shipped] Agent discovery dashboard",
				]),
			},
			repository: { full_name: REPO },
		},
	},
	{
		type: "discussion_comment",
		payload: {
			action: "created",
			discussion: {
				number: randomInt(50, 80),
				title: "[task] Agent schedule grid",
			},
			comment: {
				body: pick([
					"Claiming this for the next sprint",
					"Status update: PR ready for review",
					"Blocked on API rate limit investigation",
				]),
			},
			repository: { full_name: REPO },
		},
	},
	{
		type: "workflow_run",
		payload: {
			action: "completed",
			workflow_run: {
				name: pick(["CI", "Release", "Web CI", "Agent: April Clearwater"]),
				conclusion: pick(["success", "success", "success", "failure"]),
			},
			repository: { full_name: REPO },
		},
	},
	{
		type: "check_run",
		payload: {
			action: "completed",
			check_run: {
				name: pick(["swift build", "swift test", "biome check", "typecheck"]),
				conclusion: pick(["success", "success", "failure"]),
			},
			repository: { full_name: REPO },
		},
	},
];

function randomInt(min: number, max: number): number {
	return Math.floor(Math.random() * (max - min + 1)) + min;
}

function pick<T>(arr: T[]): T {
	return arr[Math.floor(Math.random() * arr.length)];
}

function sign(body: string, secret: string): string {
	const { createHmac } = require("node:crypto");
	return `sha256=${createHmac("sha256", secret).update(body).digest("hex")}`;
}

async function sendEvent(template?: EventTemplate): Promise<void> {
	const event = template ?? pick(templates);
	const body = JSON.stringify(event.payload);
	const deliveryId = crypto.randomUUID();

	const headers: Record<string, string> = {
		"Content-Type": "application/json",
		"X-GitHub-Event": event.type,
		"X-GitHub-Delivery": deliveryId,
	};

	const secret = process.env.GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET;
	if (secret) {
		headers["X-Hub-Signature-256"] = sign(body, secret);
	}

	const res = await fetch(`${BASE_URL}/api/webhooks/github`, {
		method: "POST",
		headers,
		body,
	});

	const status = res.ok ? "✓" : "✗";
	const summary = `${status} ${event.type}: ${JSON.stringify(event.payload.action ?? "")}`;
	console.log(`  ${summary} → ${res.status}`);
}

async function main() {
	console.log(
		`\nSimulating webhook events → ${BASE_URL}/api/webhooks/github\n`,
	);

	if (stream) {
		console.log("Streaming mode — sending 1 event every 5s (Ctrl+C to stop)\n");
		const loop = async () => {
			await sendEvent();
			setTimeout(loop, 5000);
		};
		await loop();
	} else {
		console.log(`Sending ${count} random events...\n`);
		for (let i = 0; i < count; i++) {
			await sendEvent();
		}
		console.log("\nDone.");
	}
}

main().catch(console.error);
