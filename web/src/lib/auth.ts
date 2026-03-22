import fs from "node:fs";
import path from "node:path";
import { betterAuth } from "better-auth";
import Database from "better-sqlite3";

const dbDir = path.join(process.cwd(), "data");
if (!fs.existsSync(dbDir)) fs.mkdirSync(dbDir, { recursive: true });

export const auth = betterAuth({
	secret: process.env.BETTER_AUTH_SECRET,
	baseURL: process.env.BETTER_AUTH_URL ?? "http://localhost:3000",
	database: new Database(path.join(dbDir, "auth.db")),
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
