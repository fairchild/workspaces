import Anthropic from "@anthropic-ai/sdk";
import {
	getOrCreateAgent,
	getOrCreateEnvironment,
} from "./managed-agents-cache";

const SYSTEM_PROMPT = `You are a code reviewer for a Swift project (SwiftUI / Swift Package Manager).

For each PR you receive:
1. Read the diff. Use \`git diff main...HEAD\` (or the base ref mentioned) to see what changed.
2. Explore the surrounding code — don't review in isolation. Use grep/glob to find callers, related types, and tests.
3. If the project builds with SwiftPM, run \`swift build\` and \`swift test\`. Report failures explicitly.
4. If a \`.swiftlint.yml\` exists, run \`swiftlint\` if available.
5. Post a single PR review via the GitHub MCP server with:
   - A high-level summary of the change
   - Specific comments for issues (bugs, race conditions, force-unwraps, missing tests, security, performance)
   - An overall recommendation: approve, request changes, or comment

Cite file:line for every comment. Skip nits unless they materially affect correctness or readability. Prefer fewer, higher-signal comments.`;

const TOOLS = [
	{
		type: "agent_toolset_20260401" as const,
		default_config: { enabled: true },
		configs: [
			{ name: "write", enabled: false },
			{ name: "edit", enabled: false },
			{ name: "web_search", enabled: false },
		],
	},
	{ type: "mcp_toolset" as const, mcp_server_name: "github" },
];

const MCP_SERVERS = [
	{
		type: "url" as const,
		name: "github",
		url: "https://api.githubcopilot.com/mcp/",
	},
];

export interface PrReviewPayload {
	number: number;
	title: string;
	htmlUrl: string;
	headRef: string;
	baseRef: string;
	repoUrl: string;
	repoFullName: string;
	repoName: string;
}

/**
 * Fire-and-forget: creates a Managed Agents session that reviews the PR
 * and posts a review via the GitHub MCP server. Returns the session ID,
 * or null if required env vars are missing.
 */
export async function triggerPrReview(
	payload: PrReviewPayload,
): Promise<string | null> {
	const apiKey = process.env.ANTHROPIC_API_KEY;
	const githubToken = process.env.GITHUB_TOKEN;
	const vaultId = process.env.PR_REVIEWER_VAULT_ID;

	if (!apiKey || !githubToken || !vaultId) {
		console.log(
			"[pr-review] skipping — missing ANTHROPIC_API_KEY, GITHUB_TOKEN, or PR_REVIEWER_VAULT_ID",
		);
		return null;
	}

	const client = new Anthropic({ apiKey });
	const model = process.env.PR_REVIEWER_MODEL ?? "claude-opus-4-6";

	const agentId = await getOrCreateAgent(client, {
		name: "pr-reviewer",
		model,
		systemPrompt: SYSTEM_PROMPT,
		tools: TOOLS,
		mcpServers: MCP_SERVERS,
	});

	const environmentId = await getOrCreateEnvironment(client, {
		name: "pr-reviewer-env",
		config: {
			type: "cloud",
			networking: { type: "unrestricted" },
		},
	});

	const mountPath = `/workspace/${payload.repoName}`;

	const session = await client.beta.sessions.create({
		agent: agentId,
		environment_id: environmentId,
		title: `Review PR #${payload.number}: ${payload.title}`.slice(0, 256),
		vault_ids: [vaultId],
		resources: [
			{
				type: "github_repository",
				url: payload.repoUrl,
				authorization_token: githubToken,
				mount_path: mountPath,
				checkout: { type: "branch", name: payload.headRef },
			},
		],
		metadata: {
			pr_number: String(payload.number),
			repo: payload.repoFullName,
		},
	});

	await client.beta.sessions.events.send(session.id, {
		events: [
			{
				type: "user.message",
				content: [
					{
						type: "text",
						text: `Review PR #${payload.number} on ${payload.repoFullName}.

Title: ${payload.title}
URL: ${payload.htmlUrl}
Head branch: ${payload.headRef}
Base branch: ${payload.baseRef}
Repo mounted at: ${mountPath}

Read the diff against ${payload.baseRef}, explore the surrounding code, run swift build and swift test if the project supports them, then post a single PR review via the GitHub MCP server.`,
					},
				],
			},
		],
	});

	console.log(
		`[pr-review] Session created for PR #${payload.number}: ${session.id}`,
	);
	return session.id;
}

// PR reviewer smoke test — remove after verifying
