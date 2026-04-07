#!/usr/bin/env node
/**
 * Seed the dev database with a test user and repo.
 * Used by `mise run web:dev` to ensure the dashboard loads without GitHub OAuth.
 */
const { createClient } = require("@libsql/client");
const { mkdirSync } = require("node:fs");

mkdirSync("data", { recursive: true });
const db = createClient({ url: "file:data/auth.db" });

(async () => {
	await db.execute(`CREATE TABLE IF NOT EXISTS user_repos (
		user_id TEXT NOT NULL,
		owner TEXT NOT NULL,
		repo TEXT NOT NULL,
		added_at TEXT NOT NULL DEFAULT (datetime('now')),
		PRIMARY KEY (user_id, owner, repo)
	)`);
	await db.execute({
		sql: "INSERT OR IGNORE INTO user_repos (user_id, owner, repo) VALUES (?, 'fairchild', 'workspaces')",
		args: ["dev-user"],
	});
	console.log("DB seeded: dev-user owns fairchild/workspaces");
})();
