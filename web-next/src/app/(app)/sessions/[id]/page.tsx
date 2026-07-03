/*
 * /sessions/[id] — a real session rendered in the Folio system: masthead
 * with the repo and title, the (empty, for now) transcript with its calm
 * note, and the autofocused compose. Streaming turns land with #748.
 */
import { notFound } from "next/navigation";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getRepo } from "@/lib/db/repos";
import { getSession } from "@/lib/db/sessions";
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

	return (
		<LiveSessionView
			author={author}
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
