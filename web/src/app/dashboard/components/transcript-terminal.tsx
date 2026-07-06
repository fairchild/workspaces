"use client";

import { useEffect, useRef, useState } from "react";
import styles from "./transcript-terminal.module.css";

interface TranscriptTerminalProps {
	sessionId: string;
	agentName: string;
	active: boolean;
}

interface TranscriptLine {
	key: string;
	kind: "command" | "result" | "status" | "error";
	tool?: string;
	text: string;
}

/**
 * Read-only "terminal" view for Managed Agents sessions. Streams
 * `agent.tool_use` (bash, read, write, etc.) and `agent.tool_result`
 * events as a monospace scrollback. There is no PTY here — Managed
 * Agents' bash tool is turn-based — so input is not supported.
 */
export function TranscriptTerminal({
	sessionId,
	agentName,
	active,
}: TranscriptTerminalProps) {
	const [lines, setLines] = useState<TranscriptLine[]>([]);
	const [error, setError] = useState<string | null>(null);
	const [ended, setEnded] = useState(false);
	const scrollRef = useRef<HTMLDivElement>(null);

	useEffect(() => {
		setLines([]);
		setError(null);
		setEnded(false);
		const url = `/api/managed-agents/transcript?sessionId=${encodeURIComponent(sessionId)}`;
		const source = new EventSource(url);
		source.onmessage = (ev) => {
			try {
				const data = JSON.parse(ev.data) as TranscriptLine;
				setLines((prev) => [...prev, data]);
			} catch {
				// ignore malformed line
			}
		};
		// The server sends `end` when the session can emit no further events;
		// close for real so the browser doesn't auto-reconnect forever.
		source.addEventListener("end", () => {
			setEnded(true);
			setError(null);
			source.close();
		});
		source.onerror = () => {
			setError("transcript stream disconnected");
		};
		return () => {
			source.close();
		};
	}, [sessionId]);

	// Auto-scroll to bottom whenever a new line arrives. Keying on the
	// most recent line's id makes biome happy (it sees the dep inside the
	// effect body) and naturally fires once per new event.
	const lastKey = lines[lines.length - 1]?.key;
	useEffect(() => {
		if (!active || !lastKey) return;
		const el = scrollRef.current;
		if (!el) return;
		el.scrollTop = el.scrollHeight;
	}, [lastKey, active]);

	return (
		<div
			className={styles.transcript}
			style={{ display: active ? "flex" : "none" }}
			aria-label={`Tool-call transcript for ${agentName}`}
		>
			<div ref={scrollRef} className={styles.scrollback}>
				{lines.length === 0 && (
					<div className={styles.empty}>
						Waiting for tool calls from <strong>{agentName}</strong>…
					</div>
				)}
				{lines.map((line) => (
					<div key={line.key} className={styles[`line-${line.kind}`]}>
						{line.kind === "command" && (
							<>
								<span className={styles.prompt}>
									{line.tool === "bash" ? "$" : `[${line.tool}]`}
								</span>{" "}
								<span className={styles.commandText}>{line.text}</span>
							</>
						)}
						{line.kind === "result" && (
							<pre className={styles.resultText}>{line.text}</pre>
						)}
						{line.kind === "status" && (
							<span className={styles.statusText}>{line.text}</span>
						)}
						{line.kind === "error" && (
							<span className={styles.errorText}>{line.text}</span>
						)}
					</div>
				))}
				{ended && (
					<div className={styles["line-status"]}>
						<span className={styles.statusText}>transcript complete</span>
					</div>
				)}
				{error && <div className={styles["line-error"]}>{error}</div>}
			</div>
		</div>
	);
}
