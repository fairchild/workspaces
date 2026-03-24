import { getTurso } from "./db";
import type { SelectedRepo } from "./types";

let tableReady: Promise<void> | undefined;

function ensureTable(): Promise<void> {
	if (!tableReady) {
		tableReady = getTurso()
			.execute(`
			CREATE TABLE IF NOT EXISTS user_repos (
				user_id TEXT NOT NULL,
				owner TEXT NOT NULL,
				repo TEXT NOT NULL,
				added_at TEXT NOT NULL DEFAULT (datetime('now')),
				PRIMARY KEY (user_id, owner, repo)
			)
		`)
			.then(() => {});
	}
	return tableReady;
}

export async function getUserRepos(userId: string): Promise<SelectedRepo[]> {
	await ensureTable();
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
	await ensureTable();
	const db = getTurso();
	await db.execute({
		sql: "DELETE FROM user_repos WHERE user_id = ?",
		args: [userId],
	});
	for (const r of repos) {
		await db.execute({
			sql: "INSERT INTO user_repos (user_id, owner, repo) VALUES (?, ?, ?)",
			args: [userId, r.owner, r.repo],
		});
	}
}

export async function hasUserRepos(userId: string): Promise<boolean> {
	await ensureTable();
	const result = await getTurso().execute({
		sql: "SELECT 1 FROM user_repos WHERE user_id = ? LIMIT 1",
		args: [userId],
	});
	return result.rows.length > 0;
}
