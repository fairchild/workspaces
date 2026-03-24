import { parseAgentTree } from "@/lib/agent-discovery";
import { getSession } from "@/lib/auth-server";
import {
	GitHubApiError,
	fetchFileContent,
	fetchIssuesByLabel,
	fetchOpenPRCount,
	fetchRepoTree,
	getGitHubToken,
} from "@/lib/github";
import type { AgentDiscoveryResponse, PipelineColumn } from "@/lib/types";
import { PIPELINE_GITHUB_LABELS } from "@/lib/types";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ owner: string; repo: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session)
		return Response.json({ error: "unauthorized" }, { status: 401 });

	const token = await getGitHubToken(session.user.id);
	if (!token)
		return Response.json(
			{ error: "no_github_token", needsReauth: true },
			{ status: 403 },
		);

	const { owner, repo } = await params;

	try {
		// Fetch tree and identify SKILL.md files
		const treeEntries = await fetchRepoTree(token, owner, repo);
		const skillMdPaths = treeEntries
			.filter((e) => e.path.match(/^\.agents\/skills\/[^/]+\/SKILL\.md$/))
			.map((e) => e.path);

		// Fetch SKILL.md contents in parallel
		const skillContents = new Map<string, string>();
		const contentResults = await Promise.all(
			skillMdPaths.map(async (path) => {
				const content = await fetchFileContent(token, owner, repo, path);
				return [path, content] as const;
			}),
		);
		for (const [path, content] of contentResults) {
			skillContents.set(path, content);
		}

		// Parse agents from tree
		const { agents, skills, configFiles } = parseAgentTree(
			treeEntries,
			skillContents,
		);

		// Fetch pipeline issues and PR count in parallel
		const [ready, claimed, review, mergeable, openPRs] = await Promise.all([
			fetchIssuesByLabel(token, owner, repo, PIPELINE_GITHUB_LABELS.ready),
			fetchIssuesByLabel(token, owner, repo, PIPELINE_GITHUB_LABELS.claimed),
			fetchIssuesByLabel(token, owner, repo, PIPELINE_GITHUB_LABELS.review),
			fetchIssuesByLabel(token, owner, repo, PIPELINE_GITHUB_LABELS.mergeable),
			fetchOpenPRCount(token, owner, repo),
		]);

		// Derive agent status from claimed/review issues
		const activeAgentNames = new Set<string>();
		for (const issue of [...claimed, ...review]) {
			if (issue.assignee) activeAgentNames.add(issue.assignee.toLowerCase());
		}
		for (const agent of agents) {
			if (activeAgentNames.has(agent.name.toLowerCase())) {
				agent.status = "active";
			}
		}

		const response: AgentDiscoveryResponse = {
			agents,
			skills,
			configFiles,
			pipeline: { ready, claimed, review, mergeable },
			stats: {
				agentCount: agents.length,
				skillCount: skills.length,
				openPRs,
				readyIssues: ready.length,
			},
		};

		return Response.json(response);
	} catch (err) {
		if (err instanceof GitHubApiError) {
			if (err.status === 403)
				return Response.json(
					{ error: "insufficient_scope", needsReauth: true },
					{ status: 403 },
				);
			if (err.status === 404)
				return Response.json({ error: "repo_not_found" }, { status: 404 });
		}
		throw err;
	}
}
