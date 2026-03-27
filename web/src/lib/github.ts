import { getTurso } from "./db";
import type { GitHubRepo, PipelineIssue } from "./types";

const GITHUB_API = "https://api.github.com";

// --- TTL cache ---

const cache = new Map<string, { data: unknown; expires: number }>();

async function cached<T>(
	key: string,
	ttlMs: number,
	fetcher: () => Promise<T>,
): Promise<T> {
	const entry = cache.get(key);
	if (entry && entry.expires > Date.now()) return entry.data as T;
	const data = await fetcher();
	cache.set(key, { data, expires: Date.now() + ttlMs });
	return data;
}

const FIVE_MIN = 5 * 60 * 1000;
const FIFTEEN_MIN = 15 * 60 * 1000;

// --- Token retrieval ---

export async function getGitHubToken(userId: string): Promise<string | null> {
	const result = await getTurso().execute({
		sql: "SELECT accessToken FROM account WHERE userId = ? AND providerId = 'github'",
		args: [userId],
	});
	if (result.rows.length === 0) return null;
	return result.rows[0].accessToken as string;
}

// --- GitHub API helpers ---

async function ghFetch<T>(path: string, token: string): Promise<T> {
	const res = await fetch(`${GITHUB_API}${path}`, {
		headers: {
			Authorization: `Bearer ${token}`,
			Accept: "application/vnd.github+json",
			"X-GitHub-Api-Version": "2022-11-28",
		},
	});
	if (!res.ok) {
		throw new GitHubApiError(res.status, await res.text());
	}
	return res.json();
}

export class GitHubApiError extends Error {
	constructor(
		public status: number,
		public body: string,
	) {
		super(`GitHub API ${status}: ${body.slice(0, 200)}`);
	}
}

// --- Repos ---

interface GHRepo {
	full_name: string;
	name: string;
	owner: { login: string };
	pushed_at: string;
	description: string | null;
}

export function fetchUserRepos(token: string): Promise<GitHubRepo[]> {
	const keyHash = token.slice(-8);
	return cached(`repos:${keyHash}`, FIVE_MIN, async () => {
		const repos = await ghFetch<GHRepo[]>(
			"/user/repos?sort=pushed&direction=desc&per_page=100",
			token,
		);
		return repos.map((r) => ({
			full_name: r.full_name,
			owner: r.owner.login,
			name: r.name,
			pushed_at: r.pushed_at,
			description: r.description,
		}));
	});
}

// --- Tree scan ---

interface GHTreeEntry {
	path: string;
	type: string;
	sha: string;
}

interface GHTreeResponse {
	sha: string;
	tree: GHTreeEntry[];
	truncated: boolean;
}

export interface TreeEntry {
	path: string;
	type: string;
}

export function fetchRepoTree(
	token: string,
	owner: string,
	repo: string,
): Promise<TreeEntry[]> {
	return cached(`tree:${owner}/${repo}`, FIFTEEN_MIN, async () => {
		// Get default branch SHA first
		const repoInfo = await ghFetch<{ default_branch: string }>(
			`/repos/${owner}/${repo}`,
			token,
		);
		const tree = await ghFetch<GHTreeResponse>(
			`/repos/${owner}/${repo}/git/trees/${repoInfo.default_branch}?recursive=1`,
			token,
		);
		return tree.tree
			.filter((e) => e.path.startsWith(".agents/"))
			.map((e) => ({ path: e.path, type: e.type }));
	});
}

// --- File content ---

export function fetchFileContent(
	token: string,
	owner: string,
	repo: string,
	path: string,
): Promise<string> {
	return cached(`file:${owner}/${repo}:${path}`, FIFTEEN_MIN, async () => {
		const res = await fetch(
			`${GITHUB_API}/repos/${owner}/${repo}/contents/${path}`,
			{
				headers: {
					Authorization: `Bearer ${token}`,
					Accept: "application/vnd.github.raw+json",
					"X-GitHub-Api-Version": "2022-11-28",
				},
			},
		);
		if (!res.ok) return "";
		return res.text();
	});
}

// --- Issues ---

interface GHIssue {
	number: number;
	title: string;
	labels: Array<{ name: string }>;
	assignee: { login: string } | null;
	html_url: string;
}

export function fetchIssuesByLabel(
	token: string,
	owner: string,
	repo: string,
	label: string,
): Promise<PipelineIssue[]> {
	return cached(`issues:${owner}/${repo}:${label}`, FIVE_MIN, async () => {
		const issues = await ghFetch<GHIssue[]>(
			`/repos/${owner}/${repo}/issues?labels=${encodeURIComponent(label)}&state=open&per_page=100`,
			token,
		);
		return issues.map((i) => ({
			number: i.number,
			title: i.title,
			labels: i.labels.map((l) => l.name),
			assignee: i.assignee?.login ?? null,
			url: i.html_url,
		}));
	});
}

// --- PRs ---

export function fetchOpenPRCount(
	token: string,
	owner: string,
	repo: string,
): Promise<number> {
	return cached(`prs:${owner}/${repo}`, FIVE_MIN, async () => {
		const prs = await ghFetch<unknown[]>(
			`/repos/${owner}/${repo}/pulls?state=open&per_page=100`,
			token,
		);
		return prs.length;
	});
}

// --- Discussions (GraphQL) ---

const GITHUB_GRAPHQL = "https://api.github.com/graphql";

async function ghGraphQL<T>(
	token: string,
	query: string,
	variables: Record<string, unknown>,
): Promise<T> {
	const res = await fetch(GITHUB_GRAPHQL, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${token}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({ query, variables }),
	});
	if (!res.ok) {
		throw new GitHubApiError(res.status, await res.text());
	}
	const json = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
	if (json.errors?.length) {
		throw new GitHubApiError(422, json.errors.map((e) => e.message).join("; "));
	}
	return json.data as T;
}

export async function getDiscussionCategoryId(
	token: string,
	owner: string,
	repo: string,
	categoryName = "General",
): Promise<{ repoId: string; categoryId: string }> {
	const key = `disc-cat:${owner}/${repo}:${categoryName}`;
	return cached(key, FIFTEEN_MIN, async () => {
		const data = await ghGraphQL<{
			repository: {
				id: string;
				discussionCategories: {
					nodes: Array<{ id: string; name: string }>;
				};
			};
		}>(
			token,
			`query($owner: String!, $repo: String!) {
				repository(owner: $owner, name: $repo) {
					id
					discussionCategories(first: 25) {
						nodes { id name }
					}
				}
			}`,
			{ owner, repo },
		);
		const cat = data.repository.discussionCategories.nodes.find(
			(c) => c.name === categoryName,
		);
		if (!cat) {
			throw new GitHubApiError(
				404,
				`Discussion category "${categoryName}" not found in ${owner}/${repo}`,
			);
		}
		return { repoId: data.repository.id, categoryId: cat.id };
	});
}

export interface CreatedDiscussion {
	id: string;
	url: string;
	number: number;
}

export async function createDiscussion(
	token: string,
	owner: string,
	repo: string,
	title: string,
	body: string,
	categoryName = "General",
): Promise<CreatedDiscussion> {
	const { repoId, categoryId } = await getDiscussionCategoryId(
		token,
		owner,
		repo,
		categoryName,
	);
	const data = await ghGraphQL<{
		createDiscussion: {
			discussion: { id: string; url: string; number: number };
		};
	}>(
		token,
		`mutation($input: CreateDiscussionInput!) {
			createDiscussion(input: $input) {
				discussion { id url number }
			}
		}`,
		{
			input: {
				repositoryId: repoId,
				categoryId,
				title,
				body,
			},
		},
	);
	const d = data.createDiscussion.discussion;
	return { id: d.id, url: d.url, number: d.number };
}

export async function addDiscussionComment(
	token: string,
	discussionId: string,
	body: string,
): Promise<{ id: string; url: string }> {
	const data = await ghGraphQL<{
		addDiscussionComment: {
			comment: { id: string; url: string };
		};
	}>(
		token,
		`mutation($input: AddDiscussionCommentInput!) {
			addDiscussionComment(input: $input) {
				comment { id url }
			}
		}`,
		{ input: { discussionId, body } },
	);
	return data.addDiscussionComment.comment;
}

// --- Agents dir check ---

export async function checkAgentsDir(
	token: string,
	owner: string,
	repo: string,
): Promise<boolean> {
	try {
		const res = await fetch(
			`${GITHUB_API}/repos/${owner}/${repo}/contents/.agents`,
			{
				method: "HEAD",
				headers: {
					Authorization: `Bearer ${token}`,
					"X-GitHub-Api-Version": "2022-11-28",
				},
			},
		);
		return res.ok;
	} catch {
		return false;
	}
}
