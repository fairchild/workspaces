import { betterAuth } from "better-auth";
import { getAuthBaseURL } from "./auth-base-url";
import { getDialect } from "./db";

export const auth = betterAuth({
	secret: process.env.BETTER_AUTH_SECRET,
	baseURL: getAuthBaseURL(),
	database: { dialect: getDialect(), type: "sqlite" },
	socialProviders: {
		github: {
			clientId: process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID ?? "",
			clientSecret: process.env.GITHUB_WEB_WORKSPACES_CLIENT_SECRET ?? "",
			scope: ["repo"],
		},
	},
	session: {
		cookieCache: { enabled: true, maxAge: 5 * 60 },
	},
});

export type Session = typeof auth.$Infer.Session;
