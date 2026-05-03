import { unauthorizedResponse } from "@/lib/api-auth";
import { getDevBypassToken, getSession } from "@/lib/auth-server";
import { GitHubApiError, fetchUserRepos, getGitHubToken } from "@/lib/github";
import { getUserRepos, setUserRepos } from "@/lib/repos";

const MAX_REPOS_PER_SELECTION = 100;
const OWNER_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/;
const REPO_PATTERN = /^[A-Za-z0-9._-]{1,100}$/;

function parseRequestedRepos(body: unknown):
	| {
			ok: true;
			repos: Array<{ owner: string; repo: string }>;
	  }
	| { ok: false; response: Response } {
	if (!body || typeof body !== "object" || !("repos" in body)) {
		return {
			ok: false,
			response: Response.json(
				{ error: "repos must be an array" },
				{ status: 400 },
			),
		};
	}

	const repos = (body as { repos: unknown }).repos;
	if (!Array.isArray(repos)) {
		return {
			ok: false,
			response: Response.json(
				{ error: "repos must be an array" },
				{ status: 400 },
			),
		};
	}
	if (repos.length > MAX_REPOS_PER_SELECTION) {
		return {
			ok: false,
			response: Response.json(
				{
					error: `repos cannot include more than ${MAX_REPOS_PER_SELECTION} entries`,
				},
				{ status: 400 },
			),
		};
	}

	const normalized = new Map<string, { owner: string; repo: string }>();
	for (const item of repos) {
		if (!item || typeof item !== "object") {
			return {
				ok: false,
				response: Response.json(
					{ error: "each repo must include owner and repo" },
					{ status: 400 },
				),
			};
		}
		const { owner, repo } = item as { owner?: unknown; repo?: unknown };
		if (
			typeof owner !== "string" ||
			typeof repo !== "string" ||
			!OWNER_PATTERN.test(owner) ||
			!REPO_PATTERN.test(repo)
		) {
			return {
				ok: false,
				response: Response.json(
					{ error: "each repo must include a valid owner and repo" },
					{ status: 400 },
				),
			};
		}
		normalized.set(`${owner.toLowerCase()}/${repo.toLowerCase()}`, {
			owner,
			repo,
		});
	}

	return { ok: true, repos: [...normalized.values()] };
}

async function getRequestGitHubToken(
	userId: string,
): Promise<string | Response> {
	const bypassToken = getDevBypassToken();
	if (bypassToken) return bypassToken;

	const ghToken = await getGitHubToken(userId);
	if (!ghToken) {
		return Response.json(
			{ error: "no_github_token", needsReauth: true },
			{ status: 403 },
		);
	}
	return ghToken;
}

async function verifyReposForToken(
	token: string,
	repos: Array<{ owner: string; repo: string }>,
): Promise<Array<{ owner: string; repo: string }> | Response> {
	const availableRepos = await fetchUserRepos(token);
	const byFullName = new Map(
		availableRepos.map((repo) => [repo.full_name.toLowerCase(), repo]),
	);

	const verified: Array<{ owner: string; repo: string }> = [];
	const inaccessible: string[] = [];
	for (const requested of repos) {
		const fullName = `${requested.owner}/${requested.repo}`;
		const available = byFullName.get(fullName.toLowerCase());
		if (!available) {
			inaccessible.push(fullName);
			continue;
		}
		verified.push({ owner: available.owner, repo: available.name });
	}

	if (inaccessible.length > 0) {
		return Response.json(
			{
				error: "repo_not_accessible",
				repos: inaccessible,
				needsReauth: true,
			},
			{ status: 403 },
		);
	}

	return verified;
}

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session) return unauthorizedResponse();

	const repos = await getUserRepos(session.user.id);
	return Response.json(repos);
}

export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session) return unauthorizedResponse();

	let body: unknown;
	try {
		body = await request.json();
	} catch {
		return Response.json({ error: "invalid_json" }, { status: 400 });
	}

	const parsed = parseRequestedRepos(body);
	if (!parsed.ok) return parsed.response;

	try {
		const token = await getRequestGitHubToken(session.user.id);
		if (token instanceof Response) return token;

		const verifiedRepos = await verifyReposForToken(token, parsed.repos);
		if (verifiedRepos instanceof Response) return verifiedRepos;

		await setUserRepos(session.user.id, verifiedRepos);
		return Response.json({ ok: true });
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
		}
		const message =
			err instanceof GitHubApiError
				? `GitHub API ${err.status}`
				: err instanceof Error
					? err.message
					: "unknown error";
		console.error("[/api/repos]", message, err);
		return Response.json({ error: message }, { status: 500 });
	}
}
