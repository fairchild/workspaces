"use client";

/*
 * Compose: a field with presence — autofocused on load, no placeholder or
 * hint chips, the whole field a click target, the send affordance warming
 * up only while focused. Sits over a paper gradient so the transcript
 * fades out beneath it.
 */
import { useEffect, useRef, useState } from "react";

export interface ComposeFieldProps {
	/** Names the reply target for assistive tech ("Reply to Claude"). */
	agentName: string;
	onSend?: (text: string) => void;
	/** While true, submits are held and the draft kept (turn in flight). */
	disabled?: boolean;
	/** Stops the in-flight turn (#753). While `disabled` (a turn is running)
	 * the send affordance becomes this stop — same footprint, honest verb —
	 * rather than a dead button beside new chrome. */
	onStop?: () => void;
}

export function ComposeField({ agentName, onSend, disabled, onStop }: ComposeFieldProps) {
	const inputRef = useRef<HTMLInputElement>(null);
	const [text, setText] = useState("");

	// Focus after mount rather than via the `autoFocus` attribute: an
	// SSR-rendered autoFocus focuses during hydration, and tools that add
	// attributes to the focused input (e.g. cmux's address-bar focus) then
	// trip a hydration mismatch. This covers initial mount and client-nav
	// remounts alike.
	useEffect(() => {
		inputRef.current?.focus();
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
				className="group mx-auto flex min-h-[54px] max-w-[680px] cursor-text items-center gap-[13px] rounded-[13px] border border-line-strong bg-raised py-2 pr-2 pl-[19px] shadow-field transition-[border-color,box-shadow] duration-200 hover:border-focus-line focus-within:border-focus-line focus-within:shadow-[0_0_0_3px_var(--focus-ring),var(--field-shadow)]"
				onClick={(event) => {
					if (!(event.target as HTMLElement).closest("button"))
						inputRef.current?.focus();
				}}
			>
				<span className="font-mono text-[15px] text-accent">›</span>
				<input
					ref={inputRef}
					type="text"
					aria-label={`Reply to ${agentName}`}
					value={text}
					onChange={(event) => setText(event.target.value)}
					onKeyDown={(event) => {
						if (event.key === "Enter") submit();
					}}
					className="min-w-0 flex-1 border-none bg-transparent font-serif text-compose text-ink outline-none"
				/>
				{disabled && onStop ? (
					<button
						type="button"
						title="Stop the turn"
						aria-label="Stop"
						onClick={onStop}
						className="flex h-[37px] w-[37px] shrink-0 items-center justify-center rounded-[10px] border border-line-strong text-[11px] leading-none text-muted transition-colors duration-200 hover:border-del-ink hover:text-del-ink"
					>
						■
					</button>
				) : (
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
				)}
			</div>
		</div>
	);
}
