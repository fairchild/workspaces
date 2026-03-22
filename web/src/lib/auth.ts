import { createClient } from "@libsql/client";
import { betterAuth } from "better-auth";
import { LibsqlDialect } from "./libsql-dialect";

function createAuth() {
	const turso = createClient({
		url: process.env.TURSO_DATABASE_URL ?? "file:data/auth.db",
		authToken: process.env.TURSO_AUTH_TOKEN,
	});

	return betterAuth({
		secret: process.env.BETTER_AUTH_SECRET,
		baseURL: process.env.BETTER_AUTH_URL ?? "http://localhost:3000",
		database: {
			dialect: new LibsqlDialect({ client: turso }),
			type: "sqlite",
		},
		socialProviders: {
			github: {
				clientId: process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID ?? "",
				clientSecret:
					process.env.GITHUB_WEB_WORKSPACES_CLIENT_SECRET ?? "",
			},
		},
		session: {
			cookieCache: {
				enabled: true,
				maxAge: 5 * 60,
			},
		},
	});
}

let _auth: ReturnType<typeof createAuth> | undefined;
export const auth = new Proxy({} as ReturnType<typeof createAuth>, {
	get(_, prop) {
		_auth ??= createAuth();
		return (_auth as Record<string | symbol, unknown>)[prop];
	},
});

export type Session = ReturnType<typeof createAuth>["$Infer"]["Session"];
