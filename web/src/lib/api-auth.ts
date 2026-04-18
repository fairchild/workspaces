import { isRepoOwnedByUser } from "./repos";

/** 401 helper for routes that only gate on session presence. */
export function unauthorizedResponse(): Response {
	return Response.json({ error: "unauthorized" }, { status: 401 });
}

/**
 * Returns a 403 Response if the user does not own the repo, or null
 * if they do. Callers use the shape `if (resp) return resp;` so the
 * failure path is an early return without a second if/else branch.
 * Backed by a PK-index lookup in `isRepoOwnedByUser`; safe to call
 * on every request.
 */
export async function authorizeRepoAccess(
	userId: string,
	repo: string,
): Promise<Response | null> {
	if (await isRepoOwnedByUser(userId, repo)) return null;
	return Response.json(
		{ error: "repo not in your workspace" },
		{ status: 403 },
	);
}
