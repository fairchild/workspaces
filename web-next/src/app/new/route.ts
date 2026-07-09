/*
 * GET /new?repo=<owner>/<name>[&title=…] — session-create deep link for the
 * embedded-native shell (#987): validates and resolves the repo exactly like
 * the UI's new-session action (one shared write path, lib/db/start-session),
 * creates the session on the server-default provider, and 302s to it.
 * Browser-navigated, so failures render as readable plain-text 4xx pages.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import {
	isValidRepoFullName,
	PATH_PARAM_UNSUPPORTED,
	RepoUnavailableError,
	startSession,
} from "@/lib/db/start-session";
import { cleanTitleText, MAX_TITLE_LENGTH } from "@/lib/session-title";

export const runtime = "nodejs";

function plainText(message: string, status: number): Response {
	return new Response(`${message}\n`, {
		status,
		headers: { "content-type": "text/plain; charset=utf-8" },
	});
}

export async function GET(request: Request): Promise<Response> {
	// Middleware already gates this page-path at the edge; this mirrors it so
	// the route stays safe if the matcher ever drifts.
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return auth.kind === "unauthenticated"
			? Response.redirect(new URL("/sign-in", request.url), 302)
			: plainText("not signed in as the allowed user", 403);
	}

	const params = new URL(request.url).searchParams;
	if (params.get("path") !== null) {
		return plainText(PATH_PARAM_UNSUPPORTED, 400);
	}

	const repo = params.get("repo")?.trim() ?? "";
	if (!isValidRepoFullName(repo)) {
		return plainText(
			`${repo || "(empty)"} isn't an owner/name repository — expected /new?repo=<owner>/<name>`,
			400,
		);
	}

	const title = cleanTitleText(params.get("title") ?? "");
	if (title.length > MAX_TITLE_LENGTH) {
		return plainText(
			`title must be at most ${MAX_TITLE_LENGTH} characters`,
			400,
		);
	}

	try {
		const session = await startSession(getDatabase(), repo, {
			ownerLogin: auth.user.login,
			title,
		});
		return Response.redirect(new URL(`/sessions/${session.id}`, request.url), 302);
	} catch (error) {
		if (error instanceof RepoUnavailableError) {
			return plainText(
				`${repo} doesn't exist or isn't accessible — check the name and try again.`,
				404,
			);
		}
		throw error;
	}
}
