/*
 * Pure projection for model replay after a sandbox resume falls back fresh.
 * The UI transcript keeps rich parts; this produces only the compact dialogue
 * a model needs to recover conversational context from the durable event log.
 */
import type { ProjectedEvent, SessionEventRole } from "./project-events";

// Roughly 8k chars keeps the replay under a few thousand tokens in normal
// English while leaving most of the model window for the fresh turn itself.
export const REPLAY_CONTEXT_MAX_CHARS = 8_000;
export const REPLAY_CONTEXT_TRUNCATED_MARKER =
	"[earlier conversation truncated]";

interface ReplayLine {
	role: Extract<SessionEventRole, "user" | "assistant">;
	text: string;
}

/**
 * Projects stored events into a readable User/Assistant dialogue. Only user
 * text and assistant answer text are replayed; reasoning, tool calls/results,
 * status, and errors are omitted because they are either private reasoning,
 * operational noise, or already visible in the restored working copy.
 */
export function projectReplayContext(
	events: readonly ProjectedEvent[],
	maxChars = REPLAY_CONTEXT_MAX_CHARS,
): string | null {
	const lines = replayLines(events);
	if (lines.length === 0) return null;
	const rendered = lines
		.map((line) => `${speaker(line.role)}: ${line.text.trim()}`)
		.filter((line) => !line.endsWith(": "))
		.join("\n\n");
	if (!rendered) return null;
	return capReplayContext(rendered, maxChars);
}

function replayLines(events: readonly ProjectedEvent[]): ReplayLine[] {
	const ordered = [...events].sort((a, b) => a.seq - b.seq);
	const lines: ReplayLine[] = [];
	let current: ReplayLine | undefined;

	function flush(): void {
		if (!current) return;
		const text = current.text.trim();
		if (text) lines.push({ ...current, text });
		current = undefined;
	}

	function append(role: ReplayLine["role"], text: string): void {
		if (current?.role !== role) flush();
		if (!current) current = { role, text: "" };
		current.text += text;
	}

	for (const event of ordered) {
		if (event.role === "user") {
			append("user", event.chunk.content);
			continue;
		}
		if (event.chunk.type === "text") {
			append("assistant", event.chunk.content);
			continue;
		}
		if (event.chunk.type === "done") flush();
	}
	flush();

	return lines;
}

function speaker(role: ReplayLine["role"]): "User" | "Assistant" {
	return role === "user" ? "User" : "Assistant";
}

function capReplayContext(text: string, maxChars: number): string {
	if (text.length <= maxChars) return text;
	const prefix = `${REPLAY_CONTEXT_TRUNCATED_MARKER}\n\n`;
	if (maxChars <= prefix.length) {
		return REPLAY_CONTEXT_TRUNCATED_MARKER.slice(0, Math.max(0, maxChars));
	}

	const budget = maxChars - prefix.length;
	const paragraphs = text.split("\n\n");
	const kept: string[] = [];
	let used = 0;
	for (let index = paragraphs.length - 1; index >= 0; index -= 1) {
		const paragraph = paragraphs[index];
		const separatorLength = kept.length === 0 ? 0 : 2;
		const nextLength = used + separatorLength + paragraph.length;
		if (nextLength <= budget) {
			kept.unshift(paragraph);
			used = nextLength;
			continue;
		}
		if (kept.length === 0) kept.unshift(clipParagraphTail(paragraph, budget));
		break;
	}

	return `${prefix}${kept.join("\n\n")}`.slice(0, maxChars);
}

function clipParagraphTail(paragraph: string, budget: number): string {
	const labelEnd = paragraph.indexOf(": ");
	if (labelEnd < 0) return paragraph.slice(-budget);
	const label = paragraph.slice(0, labelEnd + 2);
	const contentBudget = budget - label.length;
	if (contentBudget <= 0) return paragraph.slice(-budget);
	return `${label}${paragraph.slice(-contentBudget)}`;
}
