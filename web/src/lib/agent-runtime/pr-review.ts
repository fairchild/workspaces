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

**IMPORTANT: Write the review to a file first, then use jq to build valid JSON.** Do NOT try to embed markdown directly in a JSON string literal — newlines and special characters will break.

\`\`\`bash
# 1. Write the review body to a file (real newlines, proper markdown)
mkdir -p ./tmp
cat > ./tmp/review.md << 'REVIEW_EOF'
✅ **Approve** — Clean, behavior-preserving change with no blocking issues.

## Summary
Your summary here...

<details>
<summary>Details</summary>

- \`file.swift:42\` — description of issue

</details>
REVIEW_EOF

# 2. Use jq to build valid JSON from the file, then post
EVENT="APPROVE"  # or COMMENT or REQUEST_CHANGES
jq -n --arg body "$(cat ./tmp/review.md)" --arg event "$EVENT" \\
  '{body: $body, event: $event}' | \\
curl -s -X POST "https://api.github.com/repos/{owner}/{repo}/pulls/{number}/reviews" \\
  -H "Authorization: Bearer $TOKEN" \\
  -H "Accept: application/vnd.github+json" \\
  -d @-
\`\`\`

Use \`APPROVE\` for clean PRs, \`REQUEST_CHANGES\` for issues, \`COMMENT\` for informational reviews. Replace {owner}, {repo}, {number} with values from the kickoff message.

## Review format

Your review body MUST begin with a one-line decision banner. The first character MUST be the emoji that matches the review event you are posting:
- \`✅ **Approve** — <very brief one-line summary>\` when posting \`APPROVE\`
- \`🛑 **Request changes** — <very brief one-line summary>\` when posting \`REQUEST_CHANGES\`
- \`💬 **Comment** — <very brief one-line summary>\` when posting \`COMMENT\`

Keep the decision banner to one sentence and no more than 140 characters. It should summarize the outcome, not repeat the PR title.

- Use \`## Summary\` as a real heading
- Put the details section in a GitHub-rendered HTML details block that is collapsed by default:
  \`<details><summary>Details</summary> ... </details>\`
- Do not add the \`open\` attribute to the \`<details>\` tag
- Include a short \`## Project Thread\` section that references at least one previous PR by number and explains the relationship when previous PR context is available
- In \`## Project Thread\`, mention any labels you applied because of that relationship
- If you notice a distinct dimension of work that deserves a repo label, suggest it as a brief \`Label suggestion:\` trailer at the end of \`## Project Thread\`; prefer reusing or consolidating labels over increasing label count
- Use bullet points and code blocks
- Cite \`file:line\` for every comment
- Skip nits unless they materially affect correctness or readability
- Prefer fewer, higher-signal comments`;

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

const GITHUB_API = "https://api.github.com";
const RECENT_DESCRIPTION_COUNT = 3;
const RELATIONSHIP_CANDIDATE_COUNT = 5;
const BODY_TRUNCATE_LENGTH = 1200;

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

export interface PrContextItem {
	number: number;
	title: string;
	url: string;
	state: string;
	updatedAt: string;
	headRef: string;
	baseRef: string;
	labels: string[];
	body: string;
}

export interface PrNarrativeContext {
	recentDescriptions: PrContextItem[];
	relationshipCandidates: PrContextItem[];
	unavailableReason?: string;
}

interface GitHubPullRequest {
	number: number;
	title: string | null;
	html_url: string | null;
	state: string | null;
	updated_at: string | null;
	body: string | null;
	labels?: Array<{ name?: string | null }> | null;
	head?: { ref?: string | null } | null;
	base?: { ref?: string | null } | null;
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

function truncateBody(body: string): string {
	if (body.length <= BODY_TRUNCATE_LENGTH) return body;
	return `${body.slice(0, BODY_TRUNCATE_LENGTH).trimEnd()}\n...[truncated]`;
}

function toPrContextItem(pr: GitHubPullRequest): PrContextItem {
	return {
		number: Number(pr.number),
		title: pr.title ?? "",
		url: pr.html_url ?? "",
		state: pr.state ?? "",
		updatedAt: pr.updated_at ?? "",
		headRef: pr.head?.ref ?? "",
		baseRef: pr.base?.ref ?? "",
		labels: (pr.labels ?? [])
			.map((label) => label.name?.trim() ?? "")
			.filter((name) => name.length > 0),
		body: truncateBody(pr.body ?? ""),
	};
}

export async function fetchPrNarrativeContext(
	githubToken: string,
	payload: PrReviewPayload,
): Promise<PrNarrativeContext> {
	const [owner, repo] = payload.repoFullName.split("/");
	if (!owner || !repo) {
		return {
			recentDescriptions: [],
			relationshipCandidates: [],
			unavailableReason: "Repository owner/name was unavailable.",
		};
	}

	const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls?state=all&sort=updated&direction=desc&per_page=10`;

	try {
		const res = await fetch(url, {
			headers: {
				Authorization: `Bearer ${githubToken}`,
				Accept: "application/vnd.github+json",
				"X-GitHub-Api-Version": "2022-11-28",
			},
		});
		if (!res.ok) {
			throw new Error(`GitHub API ${res.status}`);
		}
		const prs = ((await res.json()) as GitHubPullRequest[])
			.filter((pr) => Number(pr.number) !== payload.number)
			.map(toPrContextItem);

		return {
			recentDescriptions: prs.slice(0, RECENT_DESCRIPTION_COUNT),
			relationshipCandidates: prs.slice(0, RELATIONSHIP_CANDIDATE_COUNT),
		};
	} catch (err) {
		const reason = err instanceof Error ? err.message : String(err);
		console.warn("[pr-review] previous PR context unavailable:", reason);
		return {
			recentDescriptions: [],
			relationshipCandidates: [],
			unavailableReason: reason,
		};
	}
}

function formatPrContextItem(item: PrContextItem): string {
	const description = item.body.trim() || "(no description)";
	return `- PR #${item.number}: ${item.title}
  URL: ${item.url}
  State: ${item.state}
  Updated: ${item.updatedAt}
  Branches: ${item.headRef} -> ${item.baseRef}
  Labels: ${item.labels.length > 0 ? item.labels.join(", ") : "(none)"}
  Description:
${description
	.split("\n")
	.map((line) => `    ${line}`)
	.join("\n")}`;
}

export function formatPrNarrativeContext(context: PrNarrativeContext): string {
	if (context.unavailableReason) {
		return `Previous PR context unavailable: ${context.unavailableReason}`;
	}

	if (
		context.recentDescriptions.length === 0 &&
		context.relationshipCandidates.length === 0
	) {
		return "No previous PRs were found for this repository.";
	}

	return `Most recently updated PR descriptions (always scan these 3 if present):
${context.recentDescriptions.map(formatPrContextItem).join("\n\n")}

Relationship candidates (scan the first 3; if none are clearly related, scan up to 5 and use the most clearly related):
${context.relationshipCandidates.map(formatPrContextItem).join("\n\n")}`;
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

	const narrativeContext = await fetchPrNarrativeContext(githubToken, payload);
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

Previous PR narrative context:
${formatPrNarrativeContext(narrativeContext)}

GitHub API endpoint for posting the review:
POST https://api.github.com/repos/${owner}/${repo}/pulls/${payload.number}/reviews

GitHub API endpoint for applying labels when you are highly confident a label from a related PR also applies:
POST https://api.github.com/repos/${owner}/${repo}/issues/${payload.number}/labels

Read the diff against ${payload.baseRef}, explore the surrounding code, run swift build and swift test if the project supports them, then post the review using the GitHub API with the token at /workspace/.github-token.

Your review must include a short "## Project Thread" section. Reference at least one previous PR by number and explain how this PR relates to it when previous PR context is available. If one of the first 3 relationship candidates is clearly related, use it. If none are clearly related, inspect up to 5 candidates and reference the most clearly related one. If no previous PR exists or the previous PR context is unavailable, say that explicitly instead of inventing a relationship.

Pay attention to labels on related PRs. When you are highly confident an existing label from a related PR should also apply to this PR, apply that label using the labels endpoint before posting the review. Mention the applied label in "## Project Thread". Do not apply labels on weak or speculative matches.

Also consider whether this PR reveals a distinct dimension of work that would be worth tagging with a label. The repo label set is not well managed yet; prefer labels that improve review/routing clarity while staying within the current label count or reducing it through consolidation. Do not create labels. If you see a high-value new-label opportunity, add a brief "Label suggestion:" trailer at the end of "## Project Thread".`,
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
// bot identity v2 — 02:04:23
