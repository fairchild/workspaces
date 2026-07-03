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

export interface SessionViewData {
	masthead: MastheadData;
	messages: FolioMessage[];
	/** Ledger rows that start expanded (by toolCallId). */
	openToolCallIds?: string[];
	activeTurn?: ActiveTurnData;
	statusLine: StatusLineData;
}

/** Entry stagger for the first few messages, matching the prototype. */
function riseDelay(index: number): number {
	return index < 4 ? 0.03 + index * 0.07 : 0;
}

export function SessionView({ session }: { session: SessionViewData }) {
	return (
		<>
			<SessionMasthead session={session.masthead} />
			<main className="mx-auto max-w-[680px] px-5 pt-[76px] pb-6">
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
				<ComposeField agentName={session.masthead.agentName} />
				<StatusLine status={session.statusLine} />
			</footer>
		</>
	);
}
