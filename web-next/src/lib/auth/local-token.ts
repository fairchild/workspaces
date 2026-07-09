/*
 * Node-only local serving token store. start:local and server actions use this
 * to mint/read the owner-local bearer token from WEB_NEXT_DATA_DIR; middleware
 * receives the token through WEB_NEXT_LOCAL_TOKEN because edge code cannot read
 * the filesystem.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { resolveWebNextDataDir } from "../local-data-dir";
import { assertAuthModeConfig, constantTimeEqual } from "./config";

type Env = Record<string, string | undefined>;

export const LOCAL_SIGN_IN_TOKEN_FILE = "local-sign-in-token";

export function localTokenPath(env: Env = process.env): string {
	return path.join(resolveWebNextDataDir(env), LOCAL_SIGN_IN_TOKEN_FILE);
}

function mintToken(): string {
	return crypto.randomBytes(32).toString("base64url");
}

function normalizeToken(token: string): string {
	return token.trim();
}

export function ensureLocalSignInToken(env: Env = process.env): string {
	assertAuthModeConfig(env);
	const file = localTokenPath(env);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	if (fs.existsSync(file)) {
		const existing = normalizeToken(fs.readFileSync(file, "utf8"));
		if (existing.length > 0) return existing;
	}
	const token = mintToken();
	fs.writeFileSync(file, `${token}\n`, { mode: 0o600 });
	return token;
}

export function localSignInTokenMatches(
	candidate: string | null | undefined,
	env: Env = process.env,
): boolean {
	if (!candidate) return false;
	const expected = env.WEB_NEXT_LOCAL_TOKEN ?? ensureLocalSignInToken(env);
	return constantTimeEqual(normalizeToken(candidate), expected);
}

export function localSignInUrl(port: string | number, token: string): string {
	const url = new URL(`http://localhost:${port}/sign-in`);
	url.searchParams.set("token", token);
	return url.toString();
}
