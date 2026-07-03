"use server";

/*
 * Server actions for the sessions home. Thin auth-gated shells — the
 * write-path logic lives in lib/db/start-session.ts.
 */
import { redirect } from "next/navigation";
import { requireAuthorizedUser } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { startSession } from "@/lib/db/start-session";

/** New-session flow: `repo` is an `owner/name`; creates the row and routes. */
export async function createSessionAction(formData: FormData): Promise<void> {
	await requireAuthorizedUser();
	const repo = String(formData.get("repo") ?? "");
	const session = await startSession(getDatabase(), repo);
	redirect(`/sessions/${session.id}`);
}
