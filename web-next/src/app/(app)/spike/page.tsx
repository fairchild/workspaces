"use client";

/*
 * Phase 0 spike: proves StreamChunk → UIMessageChunk → useChat end-to-end —
 * streamed text parts, dynamic tool cards, and transient status — on the
 * Folio tokens. Throwaway page; the real session view replaces it.
 */
import { useChat } from "@ai-sdk/react";
import {
	DefaultChatTransport,
	isDynamicToolUIPart,
	type DynamicToolUIPart,
	type UIMessage,
} from "ai";
import { useState } from "react";

function ToolCard({ part }: { part: DynamicToolUIPart }) {
	const running =
		part.state === "input-streaming" || part.state === "input-available";
	const failed = part.state === "output-error";
	return (
		<div
			data-testid="tool-card"
			data-tool={part.toolName}
			className="my-2 border border-line-strong bg-raised text-xs"
		>
			<div className="flex items-center gap-2 border-b border-line px-3 py-1.5">
				<span
					className={`inline-block h-1.5 w-1.5 rounded-full ${
						failed ? "bg-red-400" : running ? "animate-pulse bg-accent" : "bg-faint"
					}`}
				/>
				<span className="text-accent">{part.toolName}</span>
				{running && <span className="text-faint">running…</span>}
			</div>
			{part.input !== undefined && (
				<pre className="overflow-x-auto px-3 py-2 text-muted">
					{typeof part.input === "string"
						? part.input
						: JSON.stringify(part.input, null, 2)}
				</pre>
			)}
			{part.state === "output-available" && (
				<pre className="overflow-x-auto border-t border-line px-3 py-2 text-ink">
					{typeof part.output === "string"
						? part.output
						: JSON.stringify(part.output, null, 2)}
				</pre>
			)}
			{failed && (
				<pre className="overflow-x-auto border-t border-line px-3 py-2 text-red-400">
					{part.errorText}
				</pre>
			)}
		</div>
	);
}

function Message({ message }: { message: UIMessage }) {
	const isUser = message.role === "user";
	return (
		<div
			data-message-role={isUser ? "user" : "assistant"}
			className="animate-rise-fast"
		>
			<div className={`mb-1 text-xs ${isUser ? "text-muted" : "text-accent"}`}>
				{isUser ? "you" : "agent"}
			</div>
			<div className="text-sm leading-relaxed">
				{message.parts.map((part, i) => {
					if (part.type === "text")
						return (
							<p key={i} className="whitespace-pre-wrap text-ink">
								{part.text}
							</p>
						);
					if (isDynamicToolUIPart(part)) return <ToolCard key={i} part={part} />;
					return null;
				})}
			</div>
		</div>
	);
}

export default function SpikePage() {
	const [input, setInput] = useState("");
	const [status, setStatus] = useState<string | null>(null);
	const { messages, sendMessage, status: chatStatus } = useChat({
		transport: new DefaultChatTransport({ api: "/api/spike" }),
		onData: (part) => {
			if (part.type === "data-status")
				setStatus((part.data as { message?: string }).message ?? null);
		},
		onFinish: () => setStatus(null),
	});

	const busy = chatStatus === "streaming" || chatStatus === "submitted";
	// Status lines describe provisioning; once the agent's reply starts
	// rendering they are stale, so derive visibility from message state.
	const lastMessage = messages.at(-1);
	const replyStarted =
		lastMessage?.role === "assistant" && lastMessage.parts.length > 0;
	const visibleStatus = busy && !replyStarted ? status : null;

	return (
		<main className="mx-auto flex h-screen max-w-3xl flex-col px-6">
			<header className="flex items-baseline gap-3 border-b border-line py-4">
				<h1 className="font-serif text-2xl italic text-accent">Spaces</h1>
				<span className="text-xs text-faint">
					phase 0 spike — mock provider through the chunk adapter
				</span>
			</header>
			<div className="flex-1 space-y-6 overflow-y-auto py-6">
				{messages.length === 0 && (
					<p className="text-sm text-faint">
						Send a message to stream a simulated coding turn.
					</p>
				)}
				{messages.map((m) => (
					<Message key={m.id} message={m} />
				))}
				{visibleStatus && (
					<div className="flex items-center gap-2 text-xs text-muted">
						<span className="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-accent" />
						{visibleStatus}
					</div>
				)}
			</div>
			<form
				className="flex gap-2 border-t border-line py-4"
				onSubmit={(e) => {
					e.preventDefault();
					if (!input.trim() || busy) return;
					sendMessage({ text: input });
					setInput("");
				}}
			>
				<input
					className="flex-1 border border-line-strong bg-raised px-3 py-2 text-sm text-ink outline-none placeholder:text-faint focus:border-focus-line"
					value={input}
					onChange={(e) => setInput(e.target.value)}
					placeholder="Ask the agent to fix something…"
				/>
				<button
					type="submit"
					disabled={busy}
					className="border border-line-strong px-4 py-2 text-sm text-accent disabled:opacity-40"
				>
					{busy ? "streaming…" : "send"}
				</button>
			</form>
		</main>
	);
}
