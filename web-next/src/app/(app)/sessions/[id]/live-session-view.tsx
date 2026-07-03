"use client";

/*
 * Client shell for a real session's Folio surface. #747 scope: the
 * transcript starts empty and compose appends a local echo of the user's
 * message — immediate on screen, deliberately not persisted. #748 replaces
 * the echo with the real streamed turn loop over the session-events log.
 */
import { useState } from "react";
import {
	SessionView,
	type SessionViewData,
} from "@/components/folio/session-view";
import type { FolioMessage } from "@/components/folio/types";

export function LiveSessionView({
	session,
	author,
}: {
	session: Omit<SessionViewData, "messages">;
	/** Display name for the user's own messages. */
	author: string;
}) {
	const [messages, setMessages] = useState<FolioMessage[]>([]);

	const echoLocally = (text: string) =>
		setMessages((previous) => [
			...previous,
			{
				id: `local-${previous.length + 1}`,
				role: "user",
				metadata: { author },
				parts: [{ type: "text", text }],
			},
		]);

	return (
		<SessionView session={{ ...session, messages }} onSend={echoLocally} />
	);
}
