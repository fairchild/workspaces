import Anthropic from "@anthropic-ai/sdk";
import { getInstallationToken } from "../github-app-auth";
import {
	getOrCreateAgent,
	getOrCreateEnvironment,
} from "./managed-agents-cache";

const SYSTEM_PROMPT = `You are a code reviewer for a Swift project (SwiftUI / Swift Package Manager).

For each PR you receive:
1. Read the diff. Use \`git diff origin/main...HEAD\` to see what changed. If \`main\` is not available locally, run \`git fetch origin main\` first.
2. Explore the surrounding code — don't review in isolation. Use grep/glob to find callers, related types, and tests.
3. If the project builds with SwiftPM, run \`swift build\` and \`swift test\`. Report failures explicitly. If swift is unavailable, note this and continue.
4. If a \`.swiftlint.yml\` exists, run \`swiftlint\` if available.
5. Post a single PR review using the GitHub API.

## Posting the review

A GitHub token is mounted as a file. Find it:

\`\`\`bash
TOKEN=$(cat /workspace/.github-token 2>/dev/null || cat /mnt/session/uploads/workspace/.github-token 2>/dev/null)
\`\`\`

Post the review via curl. **Always start the body with the attribution line** — this is mandatory:

\`\`\`bash
curl -s -X POST "https://api.github.com/repos/{owner}/{repo}/pulls/{number}/reviews" \\
  -H "Authorization: Bearer $TOKEN" \\
  -H "Accept: application/vnd.github+json" \\
  -d '{
    "body": "> 🤖 **Automated review by Claude** (Managed Agent)\\n\\nyour review text here",
    "event": "COMMENT"
  }'
\`\`\`

Use \`"event": "APPROVE"\` for clean PRs, \`"event": "REQUEST_CHANGES"\` for issues, \`"event": "COMMENT"\` for informational reviews. Replace {owner}, {repo}, {number} with values from the kickoff message.

## Review format

Your review body MUST begin with this exact line:
\`> 🤖 **Automated review by Claude** (Managed Agent)\`

Followed by a blank line, then the review content:
- A high-level summary of the change
- Specific comments for issues (bugs, race conditions, force-unwraps, missing tests, security, performance)
- An overall recommendation

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

async function resolveGitHubToken(): Promise<string | null> {
	const {
		PR_REVIEWER_APP_ID,
		PR_REVIEWER_PRIVATE_KEY,
		PR_REVIEWER_INSTALLATION_ID,
	} = process.env;
	if (
		PR_REVIEWER_APP_ID &&
		PR_REVIEWER_PRIVATE_KEY &&
		PR_REVIEWER_INSTALLATION_ID
	) {
		try {
			return await getInstallationToken(
				PR_REVIEWER_APP_ID,
				PR_REVIEWER_PRIVATE_KEY,
				PR_REVIEWER_INSTALLATION_ID,
			);
		} catch (err) {
			console.error(
				"[pr-review] GitHub App token failed, falling back to PAT:",
				err,
			);
		}
	}
	return process.env.GITHUB_TOKEN ?? null;
}

/**
 * Fire-and-forget: creates a Managed Agents session that reviews the PR
 * and posts a review via the GitHub API. Returns the session ID,
 * or null if required env vars are missing.
 */
export async function triggerPrReview(
	payload: PrReviewPayload,
): Promise<string | null> {
	const apiKey = process.env.ANTHROPIC_API_KEY;
	const githubToken = await resolveGitHubToken();
	const vaultId = process.env.PR_REVIEWER_VAULT_ID;

	if (!apiKey || !githubToken) {
		console.log(
			"[pr-review] skipping — missing ANTHROPIC_API_KEY or no GitHub token available",
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
	});

	const environmentId = await getOrCreateEnvironment(client, {
		name: "pr-reviewer-env",
		config: {
			type: "cloud",
			networking: { type: "unrestricted" },
		},
	});

	// Upload the GitHub token as a file so the agent can post reviews.
	// This keeps the token out of the prompt/message stream.
	const tokenFile = await client.beta.files.upload({
		file: new File([githubToken], ".github-token", {
			type: "text/plain",
		}),
	});

	const mountPath = `/workspace/${payload.repoName}`;
	const [owner, repo] = payload.repoFullName.split("/");

	const session = await client.beta.sessions.create({
		agent: agentId,
		environment_id: environmentId,
		title: `Review PR #${payload.number}: ${payload.title}`.slice(0, 256),
		...(vaultId ? { vault_ids: [vaultId] } : {}),
		resources: [
			{
				type: "github_repository",
				url: payload.repoUrl,
				authorization_token: githubToken,
				mount_path: mountPath,
				checkout: { type: "branch", name: payload.headRef },
			},
			{
				type: "file",
				file_id: tokenFile.id,
				mount_path: "/workspace/.github-token",
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

GitHub API endpoint for posting the review:
POST https://api.github.com/repos/${owner}/${repo}/pulls/${payload.number}/reviews

Read the diff against ${payload.baseRef}, explore the surrounding code, run swift build and swift test if the project supports them, then post the review using the GitHub API with the token at /workspace/.github-token.`,
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
// post-test v3 — 14:09:50
// bot identity test — 01:52:30
