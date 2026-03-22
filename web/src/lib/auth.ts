import { createClient } from "@libsql/client";
import { betterAuth } from "better-auth";
import { LibsqlDialect } from "./libsql-dialect";

const turso = createClient({
	url: process.env.TURSO_DATABASE_URL ?? "file:data/auth.db",
	authToken: process.env.TURSO_AUTH_TOKEN,
});

export const auth = betterAuth({
	secret: process.env.BETTER_AUTH_SECRET,
	baseURL: process.env.BETTER_AUTH_URL ?? "http://localhost:3000",
	database: {
		dialect: new LibsqlDialect({ client: turso }),
		type: "sqlite",
	},
	socialProviders: {
		github: {
			clientId: process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID ?? "",
			clientSecret: process.env.GITHUB_WEB_WORKSPACES_CLIENT_SECRET ?? "",
		},
	},
	session: {
		cookieCache: {
			enabled: true,
			maxAge: 5 * 60,
		},
	},
});

export type Session = typeof auth.$Infer.Session;
