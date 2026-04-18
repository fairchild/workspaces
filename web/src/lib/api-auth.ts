import { isRepoOwnedByUser } from "./repos";

export function unauthorizedResponse(): Response {
	return Response.json({ error: "unauthorized" }, { status: 401 });
}

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
