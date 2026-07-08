"use server";

/*
 * Server actions for the sessions home. Thin auth-gated shells — the
 * write-path logic lives in lib/db/start-session.ts.
 */
import { redirect } from "next/navigation";
import { requireAuthorizedUser } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import {
	isValidRepoFullName,
	RepoUnavailableError,
	startSession,
} from "@/lib/db/start-session";

export interface CreateSessionState {
	error?: string;
}

/**
 * New-session flow: `repo` is an `owner/name`, validated against GitHub in
 * `startSession`. On success it creates the row and redirects; on a repo
 * GitHub can't find or the App can't access, it returns a calm inline error
 * instead of throwing (paired with `useActionState` in `new-session.tsx`).
 */
export async function createSessionAction(
	_prevState: CreateSessionState | null,
	formData: FormData,
): Promise<CreateSessionState> {
	const user = await requireAuthorizedUser();
	const repo = String(formData.get("repo") ?? "").trim();
	// The input's pattern blocks this in the UI; a direct POST gets the same
	// calm state instead of an unhandled server-action throw.
	if (!isValidRepoFullName(repo)) {
		return { error: `${repo || "(empty)"} isn't an owner/name repository.` };
	}
	let session: Awaited<ReturnType<typeof startSession>>;
	try {
		session = await startSession(getDatabase(), repo, user.login);
	} catch (error) {
		if (error instanceof RepoUnavailableError) {
			return {
				error: `${repo} doesn't exist or isn't accessible — check the name and try again.`,
			};
		}
		throw error;
	}
	redirect(`/sessions/${session.id}`);
}
