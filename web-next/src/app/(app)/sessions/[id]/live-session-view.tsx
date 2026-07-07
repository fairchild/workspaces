"use client";

/*
 * Client shell for a real session's Folio surface. useChat streams turns
 * from the session's chat route into the components; the transcript starts
 * from the server-projected event log, so what streamed live and what a
 * reload renders are the same messages. Token application is batched
 * (experimental_throttle), not per-chunk state.
 *
 * The model picker (#824) is owned here as client state seeded from the
 * server-resolved session: changing it PATCHes the session row and updates
 * the status line immediately, without waiting for a reload — a reload (or a
 * fresh tab) reflects the same value because page.tsx reads it back from the
 * DB. The context figure is recomputed from the live transcript on every
 * render, so it advances turn-by-turn instead of only after a reload.
 */
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";
import { useMemo, useRef, useState } from "react";
import { modelLabel } from "@/lib/agent-runtime/models";
import {
	type ActiveTurnData,
	SessionView,
	type SessionViewData,
} from "@/components/folio/session-view";
import type { FolioDataParts, FolioMessage } from "@/components/folio/types";
import { deriveContextLabel } from "@/lib/transcript/turn-stats";

/** Streamed tokens paint at most this often — batched, never per-chunk. */
const TOKEN_THROTTLE_MS = 50;

function lastUserText(messages: FolioMessage[]): string {
	const last = [...messages].reverse().find((m) => m.role === "user");
	return (
		last?.parts
			.filter((part) => part.type === "text")
			.map((part) => part.text)
			.join("") ?? ""
	);
}

export function LiveSessionView({
	sessionId,
	session,
	author,
	initialMessages,
	resume = false,
}: {
	sessionId: string;
	session: Omit<SessionViewData, "messages" | "activeTurn">;
	/** Display name for the user's own messages. */
	author: string;
	/** The persisted transcript, projected server-side from session_events. */
	initialMessages: FolioMessage[];
	/** When a turn is in flight on mount, reconnect to its tail and catch up. */
	resume?: boolean;
}) {
	// Transient provider statuses of the in-flight turn, oldest first.
	const [steps, setSteps] = useState<string[]>([]);

	// The selected model: seeded from the server-resolved session, updated
	// optimistically on change (reverted if its PATCH fails while it is still
	// the latest choice). Two orderings matter beyond the optimistic paint:
	// - PATCHes are chained (each awaits its predecessor), so rapid B→C changes
	//   cannot land in the DB out of order;
	// - `send` awaits the chain before posting, so a turn sent right after a
	//   model change runs on the model the status line shows, not the old row.
	// The chain always resolves (each link swallows its own failure), so one
	// failed PATCH never wedges later changes or sends.
	const [model, setModel] = useState(session.statusLine.model);
	const latestModelRef = useRef(session.statusLine.model);
	const modelPatchChain = useRef<Promise<void>>(Promise.resolve());
	const handleModelChange = (nextModel: string) => {
		const previous = latestModelRef.current;
		latestModelRef.current = nextModel;
		setModel(nextModel);
		const revert = () => {
			// Only revert if no newer choice superseded this one meanwhile.
			if (latestModelRef.current === nextModel) {
				latestModelRef.current = previous;
				setModel(previous);
			}
		};
		modelPatchChain.current = modelPatchChain.current.then(() =>
			fetch(`/api/sessions/${sessionId}`, {
				method: "PATCH",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ model: nextModel }),
			})
				.then((res) => {
					if (!res.ok) revert();
				})
				.catch(revert),
		);
	};

	const transport = useMemo(
		() =>
			new DefaultChatTransport<FolioMessage>({
				api: `/api/sessions/${sessionId}/chat`,
				// The server owns the transcript (the event log); a send carries
				// only the new user text.
				prepareSendMessagesRequest: ({ messages }) => ({
					body: { text: lastUserText(messages) },
				}),
				// Resume reconnects here — the durable tail route, not the send
				// endpoint's default `${api}/${chatId}/stream`.
				prepareReconnectToStreamRequest: () => ({
					api: `/api/sessions/${sessionId}/stream`,
				}),
			}),
		[sessionId],
	);

	const { messages, sendMessage, status } = useChat<FolioMessage>({
		id: sessionId,
		transport,
		messages: initialMessages,
		resume,
		experimental_throttle: TOKEN_THROTTLE_MS,
		onData: (part) => {
			if (part.type === "data-status") {
				// ai@7.0.15's DataUIPart union stopped narrowing `data` on the
				// literal type; our FolioDataParts contract fixes the shape.
				const { message } = part.data as FolioDataParts["status"];
				setSteps((current) => [...current, message]);
			}
		},
	});

	const busy = status === "submitted" || status === "streaming";
	const send = (text: string) => {
		setSteps([]);
		// Await any in-flight model PATCH first, so the turn the server starts
		// reads the session row this send was composed against.
		void modelPatchChain.current.then(() =>
			sendMessage({ text, metadata: { author } }),
		);
	};

	// The reply message exists (empty) as soon as the stream starts; keep it
	// out of the transcript until it has content — the activity article
	// stands in for it.
	const visibleMessages = messages.filter((message) => message.parts.length > 0);

	// The standalone activity article covers the gap before the streamed
	// reply renders content (provisioning statuses); once parts land, the
	// growing message itself — running ledger rows, prose — is the live
	// indicator, and a second "Claude" article would just double the label.
	const last = messages.at(-1);
	const replyStarted = last?.role === "assistant" && last.parts.length > 0;
	const activeTurn: ActiveTurnData | undefined =
		busy && !replyStarted
			? {
					agentName: session.masthead.agentName,
					action: steps.at(-1) ?? "Thinking",
					details: steps.map((text, index) => ({
						state: index === steps.length - 1 ? "current" : "done",
						text,
					})),
				}
			: undefined;

	return (
		<SessionView
			session={{
				...session,
				messages: visibleMessages,
				activeTurn,
				statusLine: {
					...session.statusLine,
					model,
					modelLabel: modelLabel(model),
					contextLabel: deriveContextLabel(visibleMessages) ?? session.statusLine.contextLabel,
				},
			}}
			onSend={send}
			composeDisabled={busy}
			onModelChange={handleModelChange}
		/>
	);
}
