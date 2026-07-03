/*
 * The Better Auth instance for real GitHub OAuth mode, over the same libSQL
 * database as the session store (tables created by migration 0002). Built
 * lazily so `next build` and bypass-mode servers never construct it. The
 * GitHub login is persisted onto the user (`githubLogin`) at sign-in — it is
 * what the allowlist checks, since emails can be private.
 */
import { betterAuth } from "better-auth";
import { getDatabase } from "../db/client";
import { LibsqlDialect } from "../db/libsql-dialect";
import { resolveAuthSecret } from "./config";

function createAuth() {
	const { client } = getDatabase();
	return betterAuth({
		secret: resolveAuthSecret(),
		baseURL: process.env.BETTER_AUTH_URL,
		database: { dialect: new LibsqlDialect({ client }), type: "sqlite" },
		socialProviders: {
			github: {
				clientId: process.env.GITHUB_OAUTH_CLIENT_ID ?? "",
				clientSecret: process.env.GITHUB_OAUTH_CLIENT_SECRET ?? "",
				mapProfileToUser: (profile) => ({ githubLogin: profile.login }),
			},
		},
		user: {
			additionalFields: {
				githubLogin: { type: "string", required: false, input: false },
			},
		},
		// Short-TTL signed cookie cache: middleware verifies freshness at the
		// edge (see session-cookie.ts) without a DB read per request.
		session: {
			cookieCache: { enabled: true, maxAge: 5 * 60 },
		},
	});
}

let instance: ReturnType<typeof createAuth> | undefined;

export function getAuth() {
	instance ??= createAuth();
	return instance;
}
