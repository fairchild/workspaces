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
import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { MODEL_OPTIONS, modelLabel } from "@/lib/agent-runtime/models";
import { sessionBranch } from "@/lib/agent-runtime/vercel-provider";
import { resolveTurn } from "@/lib/agent-runtime/turn-tail";
import type { FolioMessage } from "@fairchild/folio";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { listQueuedMessages } from "@/lib/db/queued-messages";
import { getRepo } from "@/lib/db/repos";
import { getSession, readTranscript } from "@/lib/db/sessions";
import { deriveContextLabel } from "@/lib/transcript/turn-stats";
import { LiveSessionView } from "./live-session-view";

// The tab title (#823): the persisted title when there is one, otherwise the
// app's own default — never "Untitled", matching the masthead/home rule.
export async function generateMetadata({
	params,
}: {
	params: Promise<{ id: string }>;
}): Promise<Metadata> {
	const { id } = await params;
	const session = await getSession(getDatabase(), id);
	return { title: session?.title ? `${session.title} — Spaces` : "Spaces" };
}

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
	const prAction =
		session.provider === "vercel" && repo
			? {
					head: sessionBranch(session.id),
					base: repo.defaultBranch ?? "default branch",
					enabled: session.hasBranchWork,
					reason: session.hasBranchWork ? undefined : "no checkpoints ready",
				}
			: null;

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
	const queuedMessages = await listQueuedMessages(handle, id);
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
			initialQueuedMessages={queuedMessages.map((message) => ({
				queueId: message.queueId,
				text: message.text,
				queuedAt: message.queuedAt,
				position: message.position,
			}))}
			session={{
				masthead: {
					repo: repoName,
					// null (unknown/unverified) omits the segment — never claim "main".
					branch: repo?.defaultBranch ?? null,
					// Raw — possibly "". LiveSessionView derives a client-side preview
					// from the first user message when it's empty (#823), and the
					// masthead itself falls back to "New session" display text.
					title: session.title,
					agentName: "Claude",
					// The client fills this in from the verified sandbox state (#753);
					// "" renders as absence — the masthead never guesses.
					stateLabel: "",
					pullRequest: session.pullRequest,
					pullRequestAction: prAction,
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
