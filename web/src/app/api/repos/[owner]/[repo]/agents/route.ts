import { parseAgentTree } from "@/lib/agent-discovery";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getDevBypassToken, getSession } from "@/lib/auth-server";
import {
	GitHubApiError,
	fetchFileContent,
	fetchIssuesByLabel,
	fetchOpenPRCount,
	fetchRepoTree,
	getGitHubToken,
} from "@/lib/github";
import { isRepoOwnedByUser } from "@/lib/repos";
import type { AgentDiscoveryResponse } from "@/lib/types";
import { AGENT_PIPELINE_LABEL, PIPELINE_GITHUB_LABELS } from "@/lib/types";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ owner: string; repo: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session) return unauthorizedResponse();

	const { owner, repo } = await params;
	const repoFullName = `${owner}/${repo}`;
	const repoIsSaved = await isRepoOwnedByUser(session.user.id, repoFullName);

	let token: string;
	const bypassToken = getDevBypassToken();
	if (bypassToken) {
		if (!repoIsSaved) {
			const unauthorized = await authorizeRepoAccess(
				session.user.id,
				repoFullName,
			);
			if (unauthorized) return unauthorized;
		}
		token = bypassToken;
	} else {
		const ghToken = await getGitHubToken(session.user.id);
		if (!ghToken)
			return Response.json(
				{ error: "no_github_token", needsReauth: true },
				{ status: 403 },
			);
		token = ghToken;
	}

	try {
		const treeEntries = await fetchRepoTree(token, owner, repo);
		const skillMdPaths = treeEntries
			.filter((e) => e.path.match(/^\.agents\/skills\/[^/]+\/SKILL\.md$/))
			.map((e) => e.path);

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

		const { agents, skills, configFiles } = parseAgentTree(
			treeEntries,
			skillContents,
		);

		const [ready, claimed, review, mergeable, openPRs] = await Promise.all([
			fetchIssuesByLabel(token, owner, repo, [
				AGENT_PIPELINE_LABEL,
				PIPELINE_GITHUB_LABELS.ready,
			]),
			fetchIssuesByLabel(token, owner, repo, [
				AGENT_PIPELINE_LABEL,
				PIPELINE_GITHUB_LABELS.claimed,
			]),
			fetchIssuesByLabel(token, owner, repo, [
				AGENT_PIPELINE_LABEL,
				PIPELINE_GITHUB_LABELS.review,
			]),
			fetchIssuesByLabel(token, owner, repo, [
				AGENT_PIPELINE_LABEL,
				PIPELINE_GITHUB_LABELS.mergeable,
			]),
			fetchOpenPRCount(token, owner, repo),
		]);

		// Any claimed/review issue with an agent-specific label counts as that
		// agent being active — assignees are not reliable for all bot accounts.
		if (claimed.length > 0 || review.length > 0) {
			for (const agent of agents) {
				const hasActivity = [...claimed, ...review].some((issue) =>
					issue.labels.some((l) =>
						l.toLowerCase().includes(agent.name.toLowerCase()),
					),
				);
				if (hasActivity) agent.status = "active";
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
			if (err.status === 401)
				return Response.json(
					{ error: "token_expired", needsReauth: true },
					{ status: 401 },
				);
			if (err.status === 403)
				return Response.json(
					{ error: "insufficient_scope", needsReauth: true },
					{ status: 403 },
				);
			if (err.status === 404)
				return Response.json({ error: "repo_not_found" }, { status: 404 });
		}
		const message = err instanceof Error ? err.message : "unknown error";
		console.error("[/api/repos/agents]", message, err);
		return Response.json({ error: message }, { status: 500 });
	}
}
