/*
 * Per-session ownership guard for mutating/attaching API routes. Sessions
 * created before owner stamping have a null owner and stay grandfathered; new
 * rows compare the stamped login to the current allowlisted principal.
 */
import type { Session } from "@/lib/db/sessions";

function normalizeLogin(login: string | null | undefined): string {
	return login?.trim().toLowerCase() ?? "";
}

export function sessionOwnerScopeResponse(
	session: Pick<Session, "ownerLogin">,
	actingLogin: string,
): Response | undefined {
	const ownerLogin = normalizeLogin(session.ownerLogin);
	if (!ownerLogin || ownerLogin === normalizeLogin(actingLogin)) return undefined;
	return Response.json({ error: "session belongs to another user" }, { status: 403 });
}
