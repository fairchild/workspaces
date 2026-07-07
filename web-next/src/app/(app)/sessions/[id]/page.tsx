/*
 * /sessions/[id] — a real session rendered in the Folio system: masthead
 * with the repo and title, the transcript projected server-side from the
 * persisted event log, and the autofocused compose streaming live turns
 * through the session's chat route.
 *
 * Durable-turn resume: when the last turn is still in flight, its (partial)
 * assistant message is withheld from the server-rendered transcript and the
 * client is told to resume — useChat reconnects to the tail route and replays
 * the whole message from the log, catching up to completion. Withholding avoids
 * double-rendering: the AI SDK continues an existing assistant message, so a
 * full-replay against an SSR'd prefix would duplicate it.
 */
import { notFound } from "next/navigation";
import { MODEL_OPTIONS, modelLabel } from "@/lib/agent-runtime/models";
import { resolveTurn } from "@/lib/agent-runtime/turn-tail";
import type { FolioMessage } from "@/components/folio/types";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getRepo } from "@/lib/db/repos";
import { getSession, readTranscript } from "@/lib/db/sessions";
import { deriveContextLabel } from "@/lib/transcript/turn-stats";
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

	// Is the last turn still in flight? If so, resume it on the client and
	// withhold its partial assistant message from the SSR transcript.
	const turn = await resolveTurn(handle, id);
	const resume = turn.status === "running" || turn.status === "stale";
	const activeMessageId = turn.fromSeq !== null ? `${id}:${turn.fromSeq}` : null;

	// Assistant messages carry their metadata (author, turn stats) from the
	// projection; user messages get the signed-in user's name here.
	const transcript = (await readTranscript(handle, id)) as FolioMessage[];
	const initialMessages = transcript
		.filter((message) => !(resume && message.id === activeMessageId))
		.map((message) =>
			message.role === "user"
				? { ...message, metadata: { author, ...message.metadata } }
				: message,
		);

	return (
		<LiveSessionView
			sessionId={session.id}
			author={author}
			resume={resume}
			initialMessages={initialMessages}
			session={{
				masthead: {
					repo: repoName,
					branch: repo?.defaultBranch ?? "main",
					title: session.title || "New session",
					agentName: "Claude",
					stateLabel: "idle",
				},
				statusLine: {
					model: session.model,
					modelLabel: modelLabel(session.model),
					models: MODEL_OPTIONS,
					contextLabel: deriveContextLabel(transcript),
				},
				empty: {
					title: "No turns yet.",
					hint: `Ask below — this session runs on ${repoName}.`,
				},
			}}
		/>
	);
}
