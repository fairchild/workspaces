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

/** Entry stagger for the first few messages, matching the prototype. */
function riseDelay(index: number): number {
	return index < 4 ? 0.03 + index * 0.07 : 0;
}

export interface SessionViewProps {
	session: SessionViewData;
	/** Compose submit handler (client wrappers wire this; fixtures omit it). */
	onSend?: (text: string) => void;
	/** Holds sends (keeping the draft) while a turn is streaming. */
	composeDisabled?: boolean;
}

export function SessionView({ session, onSend, composeDisabled }: SessionViewProps) {
	const isEmpty = session.messages.length === 0 && !session.activeTurn;
	return (
		<>
			<SessionMasthead session={session.masthead} />
			<main className="mx-auto max-w-[680px] px-5 pt-[76px] pb-6">
				{isEmpty && session.empty && (
					<div
						data-testid="empty-transcript"
						className="animate-rise flex flex-col items-center gap-2.5 pt-[22vh] text-center"
					>
						<p className="font-serif text-body text-muted italic">
							{session.empty.title}
						</p>
						<p className="font-mono text-caption text-faint">
							{session.empty.hint}
						</p>
					</div>
				)}
				{session.messages.map((message, index) => (
					<Message
						key={message.id}
						message={message}
						openToolCallIds={session.openToolCallIds}
						animationDelay={riseDelay(index)}
					/>
				))}
				{session.activeTurn && (
					<MessageArticle
						role="assistant"
						author={session.activeTurn.agentName}
						focal
						animationDelay={riseDelay(session.messages.length)}
					>
						<ActivityLine
							action={session.activeTurn.action}
							details={session.activeTurn.details}
						/>
					</MessageArticle>
				)}
			</main>
			<footer className="sticky bottom-0 z-[15]">
				<ComposeField
					agentName={session.masthead.agentName}
					onSend={onSend}
					disabled={composeDisabled}
				/>
				<StatusLine status={session.statusLine} />
			</footer>
		</>
	);
}
