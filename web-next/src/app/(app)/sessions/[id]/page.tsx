/*
 * /sessions/[id] — a real session rendered in the Folio system: masthead
 * with the repo and title, the transcript projected server-side from the
 * persisted event log, and the autofocused compose streaming live turns
 * through the session's chat route.
 */
import { notFound } from "next/navigation";
import type { FolioMessage } from "@/components/folio/types";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getRepo } from "@/lib/db/repos";
import { getSession, readTranscript } from "@/lib/db/sessions";
import { LiveSessionView } from "./live-session-view";

export default async function SessionPage({
	params,
}: {
	params: Promise<{ id: string }>;
}) {
	const { id } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) notFound();
	const repo = session.repoId ? await getRepo(handle, session.repoId) : undefined;
	const repoName = repo?.fullName ?? "no repository";

	// The (app) layout only renders children for the authorized user; the
	// state is re-read here for the display name on the user's own messages.
	const auth = await getAuthState();
	const author = auth.kind === "authorized" ? auth.user.name : "You";

	// Assistant messages carry their metadata (author, turn stats) from the
	// projection; user messages get the signed-in user's name here.
	const transcript = (await readTranscript(handle, id)) as FolioMessage[];
	const initialMessages = transcript.map((message) =>
		message.role === "user"
			? { ...message, metadata: { author, ...message.metadata } }
			: message,
	);

	return (
		<LiveSessionView
			sessionId={session.id}
			author={author}
			initialMessages={initialMessages}
			session={{
				masthead: {
					repo: repoName,
					branch: repo?.defaultBranch ?? "main",
					title: session.title || "New session",
					agentName: "Claude",
					stateLabel: "idle",
				},
				statusLine: { model: "opus-4.8", contextLabel: "0 ctx" },
				empty: {
					title: "No turns yet.",
					hint: `Ask below — this session runs on ${repoName}.`,
				},
			}}
		/>
	);
}
