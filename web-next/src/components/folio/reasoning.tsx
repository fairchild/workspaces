"use client";

/*
 * The thinking aside: a quiet, collapsible reasoning block that recedes — the
 * model's inner voice set apart from its answer by a hairline rule. Adopted
 * from Vercel AI Elements' Reasoning component (its auto-open-while-streaming,
 * collapse-shortly-after-done, and duration tracking), rebuilt on Radix
 * Collapsible + useControllableState and restyled to Folio tokens: mono trigger,
 * serif muted prose (Folio's InlineMarkdown, not Streamdown), a breathing accent
 * dot instead of a shadcn shimmer. A reasoning part that mounts already done
 * (a replayed or fixture turn) starts collapsed; one that mounts mid-stream
 * opens while it thinks, then folds itself away.
 */
import * as Collapsible from "@radix-ui/react-collapsible";
import { useControllableState } from "@radix-ui/react-use-controllable-state";
import {
	createContext,
	memo,
	useContext,
	useEffect,
	useRef,
	useState,
	type ComponentProps,
	type ReactNode,
} from "react";
import { InlineMarkdown } from "./inline-markdown";

type ReasoningContextValue = {
	isStreaming: boolean;
	isOpen: boolean;
	setIsOpen: (open: boolean) => void;
	duration: number | undefined;
};

const ReasoningContext = createContext<ReasoningContextValue | null>(null);

export function useReasoning(): ReasoningContextValue {
	const context = useContext(ReasoningContext);
	if (!context) {
		throw new Error("Reasoning components must be used within <Reasoning>");
	}
	return context;
}

export type ReasoningProps = ComponentProps<typeof Collapsible.Root> & {
	isStreaming?: boolean;
	open?: boolean;
	defaultOpen?: boolean;
	onOpenChange?: (open: boolean) => void;
	duration?: number;
};

/** Grace period after thinking ends before the block folds away, so the last
 * lines are readable for a beat. */
const AUTO_CLOSE_DELAY = 1000;
const MS_IN_S = 1000;

export const Reasoning = memo(function Reasoning({
	className,
	isStreaming = false,
	open,
	defaultOpen,
	onOpenChange,
	duration: durationProp,
	children,
	...props
}: ReasoningProps) {
	const [isOpen, setIsOpen] = useControllableState({
		prop: open,
		// Open only if it mounted mid-thought; a completed reasoning starts folded.
		defaultProp: defaultOpen ?? isStreaming,
		onChange: onOpenChange,
		caller: "Reasoning",
	});
	const [duration, setDuration] = useControllableState<number | undefined>({
		prop: durationProp,
		defaultProp: undefined,
		caller: "Reasoning",
	});

	const [startTime, setStartTime] = useState<number | null>(
		isStreaming ? Date.now() : null,
	);
	const wasStreaming = useRef(isStreaming);

	// Track how long the thinking took (from AI Elements): start on the first
	// streaming frame, resolve to whole seconds when it stops.
	useEffect(() => {
		if (isStreaming) {
			if (startTime === null) setStartTime(Date.now());
		} else if (startTime !== null) {
			setDuration(Math.ceil((Date.now() - startTime) / MS_IN_S));
			setStartTime(null);
		}
	}, [isStreaming, startTime, setDuration]);

	// Hold open while thinking; fold away a beat after it ends (once). A block
	// that never streamed is left at its initial (folded) state, and a manual
	// toggle is never overridden.
	useEffect(() => {
		const justStopped = wasStreaming.current && !isStreaming;
		wasStreaming.current = isStreaming;
		if (isStreaming) {
			setIsOpen(true);
			return;
		}
		if (justStopped) {
			const timer = setTimeout(() => setIsOpen(false), AUTO_CLOSE_DELAY);
			return () => clearTimeout(timer);
		}
	}, [isStreaming, setIsOpen]);

	return (
		<ReasoningContext.Provider value={{ isStreaming, isOpen, setIsOpen, duration }}>
			<Collapsible.Root
				data-testid="reasoning"
				data-streaming={isStreaming || undefined}
				className={`my-[26px] ${className ?? ""}`}
				open={isOpen}
				onOpenChange={setIsOpen}
				{...props}
			>
				{children}
			</Collapsible.Root>
		</ReasoningContext.Provider>
	);
});

function thinkingLabel(isStreaming: boolean, duration: number | undefined): ReactNode {
	if (isStreaming) {
		return (
			<span className="flex items-center gap-2 text-muted">
				<span className="animate-breathe h-1.5 w-1.5 rounded-full bg-accent" />
				<span>
					Thinking
					<span className="ellipsis-dots" />
				</span>
			</span>
		);
	}
	if (duration === undefined || duration === 0) {
		return <span>Thought for a few seconds</span>;
	}
	return <span>Thought for {duration}s</span>;
}

export type ReasoningTriggerProps = ComponentProps<typeof Collapsible.Trigger>;

export const ReasoningTrigger = memo(function ReasoningTrigger({
	className,
	children,
	...props
}: ReasoningTriggerProps) {
	const { isStreaming, isOpen, duration } = useReasoning();
	return (
		<Collapsible.Trigger
			className={`group/reasoning flex w-full items-center gap-2.5 rounded-md py-[5px] pr-2 text-left font-mono text-tool text-hint transition-colors hover:text-muted ${className ?? ""}`}
			{...props}
		>
			{children ?? (
				<>
					<span
						aria-hidden
						className={`inline-block w-2.5 origin-[45%_50%] text-[11px] transition-transform duration-[.18s] ${isOpen ? "rotate-90" : ""}`}
					>
						▸
					</span>
					{thinkingLabel(isStreaming, duration)}
				</>
			)}
		</Collapsible.Trigger>
	);
});

export type ReasoningContentProps = Omit<
	ComponentProps<typeof Collapsible.Content>,
	"children"
> & {
	children: string;
};

export const ReasoningContent = memo(function ReasoningContent({
	className,
	children,
	...props
}: ReasoningContentProps) {
	return (
		<Collapsible.Content
			data-testid="reasoning-content"
			className={`reasoning-content overflow-hidden ${className ?? ""}`}
			{...props}
		>
			<div className="animate-rise-fast mt-2.5 mb-1 border-l border-line pl-4 text-[16px] leading-[1.65] text-muted [&_code]:text-[.8em] [&_p+p]:mt-3">
				{children.split(/\n{2,}/).map((paragraph, i) => (
					<p key={i}>
						<InlineMarkdown text={paragraph} />
					</p>
				))}
			</div>
		</Collapsible.Content>
	);
});
