/*
 * The full Folio session surface: masthead, manuscript transcript (with an
 * optional in-progress turn), and the dock — compose over the dismissible
 * status line. Pure composition over data; no fixture knowledge.
 */
import { ActivityLine, type ActivityLineProps } from "./activity-line";
import { ComposeField } from "./compose-field";
import { Message, MessageArticle } from "./message";
import { SessionMasthead, type MastheadData } from "./session-masthead";
import { StatusLine, type StatusLineData } from "./status-line";
import type { ApprovalDecision } from "@/lib/agent-runtime/stream-chunk";
import type { FolioMessage } from "./types";

/** The live turn: always focal, labeled but unstamped while it works. */
export interface ActiveTurnData extends ActivityLineProps {
	agentName: string;
}

/** The calm note shown in place of an empty transcript. */
export interface EmptyTranscriptNote {
	title: string;
	hint: string;
}

export interface SessionViewData {
	masthead: MastheadData;
	messages: FolioMessage[];
	/** Ledger rows that start expanded (by toolCallId). */
	openToolCallIds?: string[];
	activeTurn?: ActiveTurnData;
	statusLine: StatusLineData;
	/** Rendered when there are no messages and no active turn. */
	empty?: EmptyTranscriptNote;
}

export interface QueuedMessageData {
	queueId: string;
	text: string;
	queuedAt: string;
	position: number;
}

/** Entry stagger for the first few messages, matching the prototype. */
function riseDelay(index: number): number {
	return index < 4 ? 0.03 + index * 0.07 : 0;
}

/**
 * Variation B: a turn is a user message plus the agent messages answering it.
 * Grouping the flat transcript this way lets us draw one soft frame per turn.
 */
interface Turn {
	key: string;
	messages: FolioMessage[];
}

function groupIntoTurns(messages: FolioMessage[]): Turn[] {
	const turns: Turn[] = [];
	for (const message of messages) {
		if (message.role === "user" || turns.length === 0) {
			turns.push({ key: message.id, messages: [message] });
		} else {
			turns[turns.length - 1].messages.push(message);
		}
	}
	return turns;
}

/** The turn's original user text — what a failed reply's Retry re-sends. */
function turnUserText(turn: Turn): string {
	return turn.messages
		.filter((message) => message.role === "user")
		.flatMap((message) => message.parts)
		.filter((part) => part.type === "text")
		.map((part) => part.text)
		.join("");
}

/**
 * The frame draws the turn's presence, so the per-message focal tick and the
 * older-context fade are cleared — otherwise a turn would signal focus twice.
 */
function withoutMessagePresence(message: FolioMessage): FolioMessage {
	if (!message.metadata) return message;
	return {
		...message,
		metadata: { ...message.metadata, focal: false, recede: false },
	};
}

function QueuedMessages({
	messages,
	onCancel,
}: {
	messages: QueuedMessageData[];
	onCancel?: (queueId: string) => void;
}) {
	if (messages.length === 0) return null;
	return (
		<div
			aria-label="Queued messages"
			className="mx-auto flex max-w-[680px] flex-col gap-2 px-5 pb-2"
		>
			{messages.map((message) => (
				<div
					key={message.queueId}
					data-testid="queued-message"
					className="flex items-start gap-3 rounded-[13px] border border-dashed border-line-strong bg-raised/95 px-4 py-3 shadow-field"
				>
					<div className="min-w-0 flex-1">
						<div className="mb-1 flex items-center gap-2 font-mono text-[10px] font-medium tracking-[.14em] text-hint uppercase">
							<span>queued</span>
							<span aria-hidden>#{message.position}</span>
						</div>
						<p className="font-serif text-[15px] leading-[1.45] text-user-ink">
							{message.text}
						</p>
					</div>
					{onCancel && (
						<button
							type="button"
							aria-label={`Cancel queued message ${message.position}`}
							title="Cancel queued message"
							onClick={() => onCancel(message.queueId)}
							className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-[8px] border border-line text-[15px] leading-none text-muted transition-colors duration-200 hover:border-del-ink hover:text-del-ink"
						>
							×
						</button>
					)}
				</div>
			))}
		</div>
	);
}

export interface SessionViewProps {
	session: SessionViewData;
	/** Compose submit handler (client wrappers wire this; fixtures omit it). */
	onSend?: (text: string) => void;
	/** Hard-disables compose when this surface cannot accept text. */
	composeDisabled?: boolean;
	/** Holds retry actions while a turn is streaming; new compose sends queue. */
	retryDisabled?: boolean;
	/** User messages waiting for the current turn to settle (#984). */
	queuedMessages?: QueuedMessageData[];
	/** Cancels an undispatched queued message. */
	onCancelQueuedMessage?: (queueId: string) => void;
	/** Model picker handler (client wrappers wire this; fixtures omit it, which
	 * leaves the status line's model as static text — see status-line.tsx). */
	onModelChange?: (id: string) => void;
	/** Inline title-edit handler (client wrappers wire this; fixtures omit it,
	 * which leaves the masthead title as static text — see session-masthead.tsx). */
	onTitleChange?: (title: string) => void;
	/** Stops the in-flight turn (#753); compose keeps Send live for queued
	 * steering while this quiet control sits beside it. Fixtures omit it. */
	onStopTurn?: () => void;
	/** Stops the session's live sandbox (#753); a quiet masthead action beside
	 * the state label. Fixtures omit it. */
	onSandboxStop?: () => void;
	/** Opens or updates the session PR (#820). Fixtures omit it. */
	onPullRequestAction?: () => void;
	onApprovalDecision?: (
		requestId: string,
		decision: ApprovalDecision,
	) => Promise<void>;
}

export function SessionView({
	session,
	onSend,
	composeDisabled,
	retryDisabled,
	queuedMessages = [],
	onCancelQueuedMessage,
	onModelChange,
	onTitleChange,
	onStopTurn,
	onSandboxStop,
	onPullRequestAction,
	onApprovalDecision,
}: SessionViewProps) {
	const isEmpty = session.messages.length === 0 && !session.activeTurn;
	const hasMastheadSubline =
		!!session.masthead.pullRequest ||
		!!session.masthead.pullRequestAction ||
		!!session.masthead.pullRequestError;
	return (
		<>
			<SessionMasthead
				session={session.masthead}
				onTitleChange={onTitleChange}
				onSandboxStop={onSandboxStop}
				onPullRequestAction={onPullRequestAction}
			/>
			{/* break-words inherits into the prose, so an unbroken token (a long
			    path, a URL) wraps instead of forcing 375px pages sideways (#753);
			    pre/diff bodies keep their own inner overflow-x scrolling. */}
			<main
				className={`mx-auto max-w-[680px] px-4 pb-6 break-words sm:px-5 ${
					hasMastheadSubline ? "pt-[104px]" : "pt-[76px]"
				}`}
			>
				{isEmpty && session.empty && (
					<div
						data-testid="empty-transcript"
						className="animate-rise flex flex-col items-center gap-2.5 pt-[22vh] text-center"
					>
						<p className="font-serif text-body text-muted italic">
							{session.empty.title}
						</p>
						<p className="font-mono text-caption text-hint">
							{session.empty.hint}
						</p>
					</div>
				)}
				{(() => {
					const orderIndex = new Map(
						session.messages.map((message, index) => [message.id, index]),
					);
					const turns = groupIntoTurns(session.messages);
					// An active turn with no prior messages still needs a frame to live in.
					const renderTurns: Turn[] =
						turns.length === 0 && session.activeTurn
							? [{ key: "active", messages: [] }]
							: turns;
					return renderTurns.map((turn, turnIndex) => {
						const recent = turnIndex === renderTurns.length - 1;
						// The most-recent turn is filled + lifted; older turns are quiet outlines.
						const frame = recent
							? "border-line-strong bg-raised shadow-card"
							: "border-line";
						const retryText = turnUserText(turn);
						return (
							<section
								key={turn.key}
								data-turn={recent ? "recent" : "past"}
								className={`animate-rise mb-9 rounded-[18px] border ${frame} px-4 py-5 sm:px-8 sm:py-7`}
							>
								{turn.messages.map((message) => (
									<Message
										key={message.id}
										message={withoutMessagePresence(message)}
										openToolCallIds={session.openToolCallIds}
										animationDelay={riseDelay(orderIndex.get(message.id) ?? 0)}
										onRetry={
											message.metadata?.error && onSend && retryText
												? () => onSend(retryText)
												: undefined
										}
										retryDisabled={retryDisabled}
										onApprovalDecision={onApprovalDecision}
									/>
								))}
								{recent && session.activeTurn && (
									<MessageArticle
										role="assistant"
										author={session.activeTurn.agentName}
										animationDelay={riseDelay(session.messages.length)}
									>
										<ActivityLine
											action={session.activeTurn.action}
											details={session.activeTurn.details}
										/>
									</MessageArticle>
								)}
							</section>
						);
					});
				})()}
			</main>
			<footer className="sticky bottom-0 z-[15]">
				<QueuedMessages
					messages={queuedMessages}
					onCancel={onCancelQueuedMessage}
				/>
				<ComposeField
					agentName={session.masthead.agentName}
					onSend={onSend}
					disabled={composeDisabled}
					onStop={onStopTurn}
				/>
				<StatusLine status={session.statusLine} onModelChange={onModelChange} />
			</footer>
		</>
	);
}
