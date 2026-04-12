import { headers } from "next/headers";

/**
 * Dev bypass is active only in development, when `DEV_BYPASS_AUTH=1`,
 * AND no real OAuth app is configured. If `GITHUB_WEB_WORKSPACES_CLIENT_ID`
 * is set the real sign-in flow always wins, even in dev.
 */
function devBypassActive(): boolean {
	return (
		process.env.NODE_ENV === "development" &&
		process.env.DEV_BYPASS_AUTH === "1" &&
		!process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID
	);
}

export async function getSession() {
	if (devBypassActive()) {
		return {
			user: {
				id: "dev-user",
				name: "Dev User",
				email: "dev@localhost",
				image: null,
				createdAt: new Date(),
				updatedAt: new Date(),
				emailVerified: false,
			},
			session: {
				id: "dev-session",
				expiresAt: new Date(Date.now() + 86400000),
			},
		};
	}
	const { auth } = await import("./auth");
	return auth.api.getSession({ headers: await headers() });
}

/**
 * GitHub token used by routes under dev bypass. If `DEV_GH_TOKEN` is set
 * (e.g. `DEV_GH_TOKEN=$(gh auth token)`) GitHub-dependent features light
 * up; otherwise callers receive a placeholder that will 401 against the
 * real GitHub API — useful for local UI work that doesn't touch GH.
 */
export function getDevBypassToken(): string | null {
	if (!devBypassActive()) return null;
	return process.env.DEV_GH_TOKEN ?? "dev-bypass-token";
}
