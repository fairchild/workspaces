#!/usr/bin/env node
/**
 * Seed the dev database with a test user and repo.
 * Used by `mise run web:dev` to ensure the dashboard loads without GitHub OAuth.
 */
import { mkdirSync } from "node:fs";
import { createClient } from "@libsql/client";

mkdirSync("data", { recursive: true });
const db = createClient({ url: "file:data/auth.db" });

(async () => {
	await db.execute(`CREATE TABLE IF NOT EXISTS "user" (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		email TEXT NOT NULL UNIQUE,
		emailVerified INTEGER NOT NULL DEFAULT 0,
		image TEXT,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS session (
		id TEXT PRIMARY KEY,
		expiresAt TEXT NOT NULL,
		token TEXT NOT NULL UNIQUE,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
		ipAddress TEXT,
		userAgent TEXT,
		userId TEXT NOT NULL,
		FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_session_userId ON session(userId)",
	);

	await db.execute(`CREATE TABLE IF NOT EXISTS account (
		id TEXT PRIMARY KEY,
		accountId TEXT NOT NULL,
		providerId TEXT NOT NULL,
		userId TEXT NOT NULL,
		accessToken TEXT,
		refreshToken TEXT,
		idToken TEXT,
		accessTokenExpiresAt TEXT,
		refreshTokenExpiresAt TEXT,
		scope TEXT,
		password TEXT,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
		FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_account_userId ON account(userId)",
	);

	await db.execute(`CREATE TABLE IF NOT EXISTS verification (
		id TEXT PRIMARY KEY,
		identifier TEXT NOT NULL,
		value TEXT NOT NULL,
		expiresAt TEXT NOT NULL,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_verification_identifier ON verification(identifier)",
	);

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
