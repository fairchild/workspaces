import { betterAuth } from "better-auth";
import { getDialect } from "./db";

function getAuthBaseURL() {
	if (process.env.BETTER_AUTH_URL) return process.env.BETTER_AUTH_URL;
	if (process.env.NODE_ENV === "development") {
		return {
			allowedHosts: ["localhost:*", "127.0.0.1:*"],
			protocol: "http" as const,
			fallback: "http://localhost:3000",
		};
	}
	return "http://localhost:3000";
}

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
