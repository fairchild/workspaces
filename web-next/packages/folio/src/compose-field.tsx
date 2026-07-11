"use client";

/*
 * Compose: a field with presence — autofocused on load, no placeholder or
 * hint chips, the whole field a click target, the send affordance warming
 * up only while focused. Sits over a paper gradient so the transcript
 * fades out beneath it.
 *
 * The field is an auto-growing textarea (#807): it starts at one line and
 * grows with the draft up to a bounded max height, then scrolls internally
 * rather than pushing the page around. Enter sends, Shift+Enter inserts a
 * newline — the peer-tool convention (Slack, Discord, ChatGPT) — so pasting
 * a stack trace or writing a multi-paragraph instruction doesn't truncate.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "react";

/** Collapse-then-grow: height tracks content, capped by the CSS max-height. */
function autoGrow(el: HTMLTextAreaElement | null) {
	if (!el) return;
	el.style.height = "auto";
	el.style.height = `${el.scrollHeight}px`;
}

export interface ComposeFieldProps {
	/** Names the reply target for assistive tech ("Reply to Claude"). */
	agentName: string;
	onSend?: (text: string) => void;
	/** Hard-disable for contexts that cannot accept text at all. */
	disabled?: boolean;
	/** Stops the in-flight turn (#753). Mid-turn steering keeps Send live, so
	 * Stop sits beside it instead of replacing it. */
	onStop?: () => void;
}

export function ComposeField({ agentName, onSend, disabled, onStop }: ComposeFieldProps) {
	const textareaRef = useRef<HTMLTextAreaElement>(null);
	const [text, setText] = useState("");

	// Focus after mount rather than via the `autoFocus` attribute: an
	// SSR-rendered autoFocus focuses during hydration, and tools that add
	// attributes to the focused input (e.g. cmux's address-bar focus) then
	// trip a hydration mismatch. This covers initial mount and client-nav
	// remounts alike.
	useEffect(() => {
		textareaRef.current?.focus();
	}, []);

	// Re-measure on every keystroke (and on mount, e.g. a draft restored from
	// elsewhere): collapse to one line first so a deleted line shrinks the
	// field back down, then grow to the content's natural height, capped by
	// the CSS max-height — which is what makes it scroll instead of growing
	// past the bound. Layout-effect so the resize lands before paint (no
	// visible jump on the growing keystroke).
	useLayoutEffect(() => {
		autoGrow(textareaRef.current);
	}, [text]);

	// Wrapping also changes when the field gets narrower or wider (viewport
	// resize, mobile rotation) with no text change, so a keystroke-only
	// re-measure would leave a stale height. Width is what drives rewrapping;
	// gating on it also keeps the observer loop-safe (autoGrow writes height,
	// never width). Codex finding (gpt-5.5, xhigh).
	useEffect(() => {
		const el = textareaRef.current;
		if (!el) return;
		let lastWidth = el.clientWidth;
		const observer = new ResizeObserver(() => {
			if (el.clientWidth === lastWidth) return;
			lastWidth = el.clientWidth;
			autoGrow(el);
		});
		observer.observe(el);
		return () => observer.disconnect();
	}, []);

	const submit = () => {
		const trimmed = text.trim();
		if (trimmed.length === 0 || disabled) return;
		onSend?.(trimmed);
		setText("");
	};

	return (
		<div className="bg-[linear-gradient(to_top,var(--paper)_66%,var(--paper-0))] px-5 pt-11 pb-5">
			<div
				data-compose-boundary
				className="group mx-auto flex min-h-[54px] max-w-[680px] cursor-text items-end gap-[13px] rounded-[13px] border border-line-strong bg-raised py-2 pr-2 pl-[19px] shadow-field transition-[border-color,box-shadow] duration-200 hover:border-focus-line focus-within:border-focus-line focus-within:shadow-[0_0_0_3px_var(--focus-ring),var(--field-shadow)]"
				onClick={(event) => {
					if (!(event.target as HTMLElement).closest("button"))
						textareaRef.current?.focus();
				}}
			>
				<span aria-hidden className="mb-[7px] font-mono text-[15px] text-accent">
					›
				</span>
				<textarea
					ref={textareaRef}
					rows={1}
					aria-label={`Reply to ${agentName}`}
					value={text}
					onChange={(event) => setText(event.target.value)}
					onKeyDown={(event) => {
						if (
							event.key === "Enter" &&
							!event.shiftKey &&
							!event.nativeEvent.isComposing
						) {
							event.preventDefault();
							submit();
						}
					}}
					// Bounded growth (#807): past this height the draft scrolls inside
					// the field instead of growing the field (and the page) forever.
					className="my-[7px] max-h-[168px] min-w-0 flex-1 resize-none overflow-y-auto border-none bg-transparent font-serif text-compose text-ink outline-none"
				/>
				<div className="relative z-[1] flex shrink-0 items-center gap-2">
					{onStop && (
						<button
							type="button"
							title="Stop the turn"
							aria-label="Stop"
							onClick={onStop}
							className="flex h-[37px] w-[37px] shrink-0 items-center justify-center rounded-[10px] border border-line-strong text-[11px] leading-none text-muted transition-colors duration-200 hover:border-del-ink hover:text-del-ink"
						>
							■
						</button>
					)}
					<button
						type="button"
						title="Send"
						aria-label="Send"
						disabled={disabled}
						onClick={submit}
						className="flex h-[37px] w-[37px] shrink-0 items-center justify-center rounded-[10px] border border-line-strong text-[15px] leading-none text-muted transition-colors duration-200 group-focus-within:border-accent group-focus-within:bg-accent group-focus-within:text-send-ink hover:border-accent hover:text-accent disabled:opacity-40 disabled:group-focus-within:border-line-strong disabled:group-focus-within:bg-transparent disabled:group-focus-within:text-muted disabled:hover:border-line-strong disabled:hover:text-muted"
					>
						↑
					</button>
				</div>
			</div>
		</div>
	);
}
