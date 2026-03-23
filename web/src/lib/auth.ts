import { betterAuth } from "better-auth";
import { dialect } from "./db";

export const auth = betterAuth({
	secret: process.env.BETTER_AUTH_SECRET,
	baseURL: process.env.BETTER_AUTH_URL ?? "http://localhost:3000",
	database: { dialect, type: "sqlite" },
	socialProviders: {
		github: {
			clientId: process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID ?? "",
			clientSecret: process.env.GITHUB_WEB_WORKSPACES_CLIENT_SECRET ?? "",
		},
	},
	session: {
		cookieCache: { enabled: true, maxAge: 5 * 60 },
	},
});

export type Session = typeof auth.$Infer.Session;
