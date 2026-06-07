import { getTurso } from "./db";
import { ensureSchema } from "./schema";
import type { SelectedRepo } from "./types";

export async function getUserRepos(userId: string): Promise<SelectedRepo[]> {
	await ensureSchema();
	const result = await getTurso().execute({
		sql: "SELECT owner, repo, added_at FROM user_repos WHERE user_id = ? ORDER BY added_at",
		args: [userId],
	});
	return result.rows.map((row) => ({
		owner: row.owner as string,
		repo: row.repo as string,
		addedAt: row.added_at as string,
	}));
}

export async function setUserRepos(
	userId: string,
	repos: Array<{ owner: string; repo: string }>,
): Promise<void> {
	await ensureSchema();
	const db = getTurso();
	await db.execute({
		sql: "DELETE FROM user_repos WHERE user_id = ?",
		args: [userId],
	});
	await Promise.all(
		repos.map((r) =>
			db.execute({
				sql: "INSERT INTO user_repos (user_id, owner, repo) VALUES (?, ?, ?)",
				args: [userId, r.owner, r.repo],
			}),
		),
	);
}

export async function hasUserRepos(userId: string): Promise<boolean> {
	await ensureSchema();
	const result = await getTurso().execute({
		sql: "SELECT 1 FROM user_repos WHERE user_id = ? LIMIT 1",
		args: [userId],
	});
	return result.rows.length > 0;
}

export async function isRepoOwnedByUser(
	userId: string,
	repo: string,
): Promise<boolean> {
	const [owner, name] = repo.split("/");
	if (!owner || !name) return false;
	await ensureSchema();
	const result = await getTurso().execute({
		sql: "SELECT 1 FROM user_repos WHERE user_id = ? AND owner = ? AND repo = ? LIMIT 1",
		args: [userId, owner, name],
	});
	return result.rows.length > 0;
}
