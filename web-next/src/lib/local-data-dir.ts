/*
 * Shared local storage resolution for single-machine runs. The app keeps the
 * SQLite default and local-mode sign-in token under one owner-controlled data
 * directory so a native host can relocate both with WEB_NEXT_DATA_DIR.
 */
import path from "node:path";

type Env = Record<string, string | undefined>;

export function resolveWebNextDataDir(env: Env = process.env): string {
	const configured = env.WEB_NEXT_DATA_DIR?.trim();
	return configured && configured.length > 0 ? configured : ".data";
}

export function resolveSessionsDatabaseUrl(env: Env = process.env): string {
	if (env.SESSIONS_DATABASE_URL) return env.SESSIONS_DATABASE_URL;
	return `file:${path.join(resolveWebNextDataDir(env), "sessions.db")}`;
}
