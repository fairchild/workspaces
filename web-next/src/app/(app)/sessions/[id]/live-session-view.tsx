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
 *
 * The title (#823) follows the same seeded-client-state + PATCH-chain shape
 * as the model, plus one addition: while the session has no persisted title
 * yet, the masthead shows a *client-derived preview* — `deriveSessionTitle`
 * run against the first visible user message, the exact pure function the
 * server runs durably at turn-start (turn-ingest.ts) — so the title appears
 * the instant the first message lands instead of waiting for a reload. A
 * reload always agrees because both sides compute the same function over the
 * same text; a user edit (or the eventual server write) replaces the preview
 * with the real persisted string.
 *
 * A turn that errors (#808) surfaces the same way live and after a reload.
 * Live: `status === "error"` records the trailing assistant message's id
 * against the error text (see live-turn-error.ts's `recordLiveTurnError` —
 * the SDK's error throw cuts the stream before the adapter's `finish` chunk,
 * which would normally carry `metadata.error`, ever arrives) in a *sticky*
 * `liveFailures` map, not a value re-derived from the hook's current status —
 * a status-gated patch would un-tag an earlier failed turn the instant a
 * later turn's Retry moves `status` off "error", making its card vanish
 * until the next reload. Reload: project-events.ts tags it server-side from
 * the persisted `error`/aborted-`done` chunks — independently durable, so a
 * turn's failure card survives even if the live map above were somehow lost
 * (e.g. this component remounting). Either way the message flows into
 * `visibleMessages` and renders through Message's failure card; its Retry
 * button (session-view.tsx) re-sends the turn's original text, which `send`
 * already exists to do.
 */
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ApprovalDecision } from "@/lib/agent-runtime/stream-chunk";
import { modelLabel } from "@/lib/agent-runtime/models";
import {
	type ActiveTurnData,
	type QueuedMessageData,
	SessionView,
	type SessionViewData,
} from "@/components/folio/session-view";
import type { FolioDataParts, FolioMessage } from "@/components/folio/types";
import { TerminalDrawer } from "@/components/terminal/terminal-drawer";
import { deriveSessionTitle } from "@/lib/session-title";
import {
	applyLiveTurnErrors,
	isVisibleMessage,
	type LiveTurnErrors,
	recordLiveTurnError,
} from "@/lib/transcript/live-turn-error";
import { deriveContextLabel } from "@/lib/transcript/turn-stats";
import { sandboxStateLabel, useSandboxState } from "./use-sandbox-state";

/** Streamed tokens paint at most this often — batched, never per-chunk. */
const TOKEN_THROTTLE_MS = 50;

interface SessionSnapshot {
	turn?: { status: "none" | "running" | "done" | "stale"; fromSeq: number | null };
	messages?: FolioMessage[];
	queuedMessages?: QueuedMessageData[];
}

function lastUserText(messages: FolioMessage[]): string {
	const last = [...messages].reverse().find((m) => m.role === "user");
	return (
		last?.parts
			.filter((part) => part.type === "text")
			.map((part) => part.text)
			.join("") ?? ""
	);
}

function firstUserText(messages: FolioMessage[]): string {
	const first = messages.find((m) => m.role === "user");
	return (
		first?.parts
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
	initialQueuedMessages = [],
	resume = false,
}: {
	sessionId: string;
	session: Omit<SessionViewData, "messages" | "activeTurn">;
	/** Display name for the user's own messages. */
	author: string;
	/** The persisted transcript, projected server-side from session_events. */
	initialMessages: FolioMessage[];
	/** Durable mid-turn user messages that have not dispatched yet. */
	initialQueuedMessages?: QueuedMessageData[];
	/** When a turn is in flight on mount, reconnect to its tail and catch up. */
	resume?: boolean;
}) {
	// Transient provider statuses of the in-flight turn, oldest first.
	const [steps, setSteps] = useState<string[]>([]);
	const [queuedMessages, setQueuedMessages] = useState<QueuedMessageData[]>(
		initialQueuedMessages,
	);
	const queuedMessagesRef = useRef(queuedMessages);
	useEffect(() => {
		queuedMessagesRef.current = queuedMessages;
	}, [queuedMessages]);

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

	// The persisted title, "" until either the auto-titler or an edit sets one.
	// Same seeded-state + chained-PATCH-with-revert shape as the model above.
	const [title, setTitle] = useState(session.masthead.title);
	const latestTitleRef = useRef(session.masthead.title);
	const titlePatchChain = useRef<Promise<void>>(Promise.resolve());
	const handleTitleChange = (nextTitle: string) => {
		const previous = latestTitleRef.current;
		latestTitleRef.current = nextTitle;
		setTitle(nextTitle);
		const revert = () => {
			if (latestTitleRef.current === nextTitle) {
				latestTitleRef.current = previous;
				setTitle(previous);
			}
		};
		titlePatchChain.current = titlePatchChain.current.then(() =>
			fetch(`/api/sessions/${sessionId}`, {
				method: "PATCH",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ title: nextTitle }),
			})
				.then(async (res) => {
					if (!res.ok) {
						revert();
						return;
					}
					// The route cleans the title server-side (trim + whitespace
					// collapse), which can differ from the raw optimistic text (e.g.
					// "Fix   the  bug" → "Fix the bug") — reconcile so the display
					// matches what's actually persisted, unless a newer edit has
					// already superseded this one.
					const data = (await res.json().catch(() => null)) as {
						title?: string;
					} | null;
					if (
						data?.title &&
						data.title !== nextTitle &&
						latestTitleRef.current === nextTitle
					) {
						latestTitleRef.current = data.title;
						setTitle(data.title);
					}
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

	const {
		messages,
		setMessages,
		sendMessage,
		resumeStream,
		status,
		error,
	} = useChat<FolioMessage>({
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
	const hasSeenBusyRef = useRef(false);
	useEffect(() => {
		if (busy) hasSeenBusyRef.current = true;
	}, [busy]);
	const refreshInFlightRef = useRef(false);
	const refreshSessionFromServer = useCallback(async () => {
		if (refreshInFlightRef.current) return;
		refreshInFlightRef.current = true;
		try {
			const res = await fetch(`/api/sessions/${sessionId}`);
			if (!res.ok) return;
			const data = (await res.json()) as SessionSnapshot;
			if (data.messages) setMessages(data.messages);
			setQueuedMessages(data.queuedMessages ?? []);
			if (data.turn?.status === "running" || data.turn?.status === "stale") {
				void resumeStream();
			}
		} finally {
			refreshInFlightRef.current = false;
		}
	}, [sessionId, setMessages, resumeStream]);
	const queueKey = queuedMessages.map((message) => message.queueId).join("|");
	const lastQueueKickRef = useRef("");
	useEffect(() => {
		if (resume && !hasSeenBusyRef.current) return;
		if (busy || queueKey.length === 0) {
			if (queueKey.length === 0) lastQueueKickRef.current = "";
			return;
		}
		if (lastQueueKickRef.current === queueKey) return;
		lastQueueKickRef.current = queueKey;
		void refreshSessionFromServer();
	}, [busy, queueKey, refreshSessionFromServer, resume]);

	// The sandbox lifecycle surface (#753): a verified state in the masthead,
	// and two honest controls — stop the in-flight turn (the compose's send
	// affordance while busy), stop the live VM (a quiet masthead action).
	const { sandbox, stopSandbox } = useSandboxState(sessionId, busy);
	const stopTurn = () => {
		// On success the UI follows the stream, not this request: the server
		// closes the turn's log, the tail surfaces the stop as this turn's
		// failure card ("Turn stopped."), and the hook's status transition
		// re-enables compose. A refusal is surfaced as an activity step — the
		// one case a shown control can't act (the turn's runner lives on
		// another server instance) must not be a silent click (codex finding,
		// gpt-5.5 xhigh). The benign 409 right after the turn finished on its
		// own adds a step nothing renders: the activity line is already gone.
		void (async () => {
			try {
				const res = await fetch(`/api/sessions/${sessionId}/stop`, {
					method: "POST",
				});
				if (!res.ok) {
					const data = (await res.json().catch(() => null)) as {
						error?: string;
					} | null;
					setSteps((current) => [
						...current,
						`Stop unavailable — ${data?.error ?? `HTTP ${res.status}`}`,
					]);
				}
			} catch {
				setSteps((current) => [...current, "Stop unavailable — network error"]);
			}
		})();
	};

	const answerApproval = async (
		requestId: string,
		decision: ApprovalDecision,
	): Promise<void> => {
		const res = await fetch(`/api/sessions/${sessionId}/approvals/${requestId}`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ decision }),
		});
		if (!res.ok) {
			const data = (await res.json().catch(() => null)) as {
				error?: string;
			} | null;
			throw new Error(data?.error ?? `approval failed (${res.status})`);
		}
	};

	const queueMessage = useCallback(
		async (text: string) => {
			try {
				const res = await fetch(`/api/sessions/${sessionId}/chat`, {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ text, queue: true }),
				});
				if (res.status !== 202) {
					await refreshSessionFromServer();
					if (!res.ok) {
						const data = (await res.json().catch(() => null)) as {
							error?: string;
						} | null;
						setSteps((current) => [
							...current,
							`Queue unavailable — ${data?.error ?? `HTTP ${res.status}`}`,
						]);
					}
					return;
				}
				const data = (await res.json()) as {
					queued?: boolean;
					queueId?: string;
					position?: number;
				};
				if (!data.queued || !data.queueId) {
					await refreshSessionFromServer();
					return;
				}
				const queueId = data.queueId;
				setQueuedMessages((current) =>
					[
						...current.filter((message) => message.queueId !== queueId),
						{
							queueId,
							text,
							queuedAt: new Date().toISOString(),
							position: data.position ?? current.length + 1,
						},
					].sort((a, b) => a.position - b.position),
				);
			} catch {
				setSteps((current) => [...current, "Queue unavailable — network error"]);
			}
		},
		[sessionId, refreshSessionFromServer],
	);

	const send = (text: string) => {
		setSteps([]);
		// Await any in-flight model PATCH first, so the turn the server starts
		// reads the session row this send was composed against.
		void modelPatchChain.current.then(() => {
			if (busy) return queueMessage(text);
			return sendMessage({ text, metadata: { author } });
		});
	};

	const cancelQueuedMessage = useCallback(
		(queueId: string) => {
			const previous = queuedMessagesRef.current;
			setQueuedMessages((current) =>
				current.filter((message) => message.queueId !== queueId),
			);
			void fetch(`/api/sessions/${sessionId}/queue/${queueId}`, {
				method: "DELETE",
			})
				.then(async (res) => {
					if (!res.ok) await refreshSessionFromServer();
				})
				.catch(() => {
					setQueuedMessages(previous);
				});
		},
		[sessionId, refreshSessionFromServer],
	);

	// A live failure (#808): the trailing assistant message useChat pushed at
	// the turn's `start` never gets `metadata.error` from the stream itself
	// (see live-turn-error.ts), so record it here from the hook's own error
	// state the moment it appears. Sticky by message id (real state, not a
	// value re-derived from the current `status`) — a later turn's own
	// status transitions must not erase an earlier turn's recorded failure.
	const [liveFailures, setLiveFailures] = useState<LiveTurnErrors>({});
	useEffect(() => {
		if (status !== "error" || !error) return;
		setLiveFailures((current) => recordLiveTurnError(current, messages, error.message));
	}, [status, error, messages]);
	const displayMessages = useMemo(
		() => applyLiveTurnErrors(messages, liveFailures, session.masthead.agentName),
		[messages, liveFailures, session.masthead.agentName],
	);

	// The reply message exists (empty) as soon as the stream starts; keep it
	// out of the transcript until it has content or has failed — the activity
	// article stands in for an in-progress, contentless reply.
	const visibleMessages = displayMessages.filter(isVisibleMessage);

	// The standalone activity article covers the gap before the streamed
	// reply renders content (provisioning statuses); once parts land, the
	// growing message itself — running ledger rows, prose — is the live
	// indicator, and a second "Claude" article would just double the label.
	const last = displayMessages.at(-1);
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

	// Before the session has a real title, show the same derivation the
	// server will persist durably at turn-start — computed here purely for
	// instant paint, never written from the client.
	const displayTitle = useMemo(
		() => title || deriveSessionTitle(firstUserText(visibleMessages)),
		[title, visibleMessages],
	);

	useEffect(() => {
		document.title = displayTitle ? `${displayTitle} — Spaces` : "Spaces";
	}, [displayTitle]);

	return (
		<>
			<TerminalDrawer sessionId={sessionId} />
			<SessionView
				session={{
					...session,
					messages: visibleMessages,
					activeTurn,
					masthead: {
						...session.masthead,
						title: displayTitle,
						stateLabel: sandboxStateLabel(sandbox),
						live: sandbox?.state === "live",
					},
					statusLine: {
						...session.statusLine,
						model,
						modelLabel: modelLabel(model),
						contextLabel:
							deriveContextLabel(visibleMessages) ?? session.statusLine.contextLabel,
					},
				}}
				onSend={send}
				retryDisabled={busy}
				queuedMessages={queuedMessages}
				onCancelQueuedMessage={cancelQueuedMessage}
				onModelChange={handleModelChange}
				onTitleChange={handleTitleChange}
				onStopTurn={busy ? stopTurn : undefined}
				onSandboxStop={
					sandbox?.state === "live" && !busy ? () => void stopSandbox() : undefined
				}
				onApprovalDecision={answerApproval}
			/>
		</>
	);
}
