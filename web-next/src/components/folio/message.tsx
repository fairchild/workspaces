/*
 * The manuscript message: serif prose paragraphs with contiguous tool
 * parts grouped into a quiet "workings" apparatus and an end-of-turn
 * receipt. A landed edit has one home — its Edit ledger row expands to
 * reveal its diff inline (#790); there is no separate floating diff card.
 * Consumes AI SDK UIMessages (text / dynamic-tool parts) so live streaming
 * (#748) renders through the same component.
 */
import { isDynamicToolUIPart, type DynamicToolUIPart } from "ai";
import type { CSSProperties, ReactNode } from "react";
import { DiffHunk } from "./diff-card";
import { InlineMarkdown } from "./inline-markdown";
import {
	contextualOpenToolCallId,
	describeToolPart,
	type LedgerBody,
	type LedgerMeta,
} from "./ledger";
import { Reasoning, ReasoningContent, ReasoningTrigger } from "./reasoning";
import { TestOutputPanel } from "./test-output-panel";
import { ToolLedgerRow } from "./tool-ledger-row";
import { TurnStatsReceipt } from "./turn-stats";
import type { FolioMessage } from "./types";

// --- shell -------------------------------------------------------------------

export interface MessageArticleProps {
	role: "user" | "assistant";
	author: string;
	stamp?: string;
	focal?: boolean;
	recede?: boolean;
	animationDelay?: number;
	children: ReactNode;
}

const FOCAL_CLASSES =
	"before:absolute before:-left-[22px] before:top-[3px] before:bottom-[3px] before:w-[2px] before:rounded-[2px] before:bg-accent before:opacity-[.42] before:content-['']";

/**
 * Article + author label shared by regular messages and the in-progress
 * turn. `focal` draws the gutter tick; `recede` fades older context.
 */
export function MessageArticle({
	role,
	author,
	stamp,
	focal,
	recede,
	animationDelay,
	children,
}: MessageArticleProps) {
	return (
		<article
			data-message-role={role}
			data-focal={focal || undefined}
			className={`group animate-rise relative mb-6 last:mb-0 [&_p+p]:mt-4 ${recede ? "opacity-[.76]" : ""} ${focal ? FOCAL_CLASSES : ""}`}
			style={
				animationDelay
					? ({ animationDelay: `${animationDelay}s` } satisfies CSSProperties)
					: undefined
			}
		>
			<div className="mb-3.5 flex items-baseline gap-3 font-mono text-label font-medium tracking-[.16em] uppercase text-faint">
				{role === "user" && (
					<span aria-hidden className="h-px w-3.5 self-center bg-faint" />
				)}
				{author}
				{stamp !== undefined && (
					<span className="font-normal tracking-[.04em] opacity-0 transition-opacity duration-[.25s] group-hover:opacity-80">
						{stamp}
					</span>
				)}
			</div>
			{children}
		</article>
	);
}

// --- part grouping -----------------------------------------------------------

type Segment =
	| { kind: "text"; key: string; text: string }
	| { kind: "reasoning"; key: string; text: string; streaming: boolean }
	| { kind: "tools"; key: string; parts: DynamicToolUIPart[] };

/** Contiguous tool parts collapse into one workings block. */
function groupParts(parts: FolioMessage["parts"]): Segment[] {
	const segments: Segment[] = [];
	parts.forEach((part, index) => {
		if (part.type === "text") {
			segments.push({ kind: "text", key: `part-${index}`, text: part.text });
		} else if (part.type === "reasoning") {
			segments.push({
				kind: "reasoning",
				key: `part-${index}`,
				text: part.text,
				streaming: part.state === "streaming",
			});
		} else if (isDynamicToolUIPart(part)) {
			const last = segments.at(-1);
			if (last?.kind === "tools") last.parts.push(part);
			else segments.push({ kind: "tools", key: `part-${index}`, parts: [part] });
		}
	});
	return segments;
}

// --- ledger row rendering ------------------------------------------------------

function LedgerMetaView({ meta }: { meta: LedgerMeta }) {
	if (meta.kind === "delta") {
		return (
			<>
				<span className="text-add-ink">+{meta.additions}</span>{" "}
				<span className="text-del-ink">−{meta.deletions}</span>
			</>
		);
	}
	return meta.text;
}

function LedgerBodyView({ body }: { body: LedgerBody }) {
	if (body.kind === "test-output")
		return <TestOutputPanel output={body.content} passed={body.passed} />;
	if (body.kind === "diff") return <DiffHunk lines={body.diff.lines} />;
	return (
		<pre className="overflow-x-auto rounded-lg border border-line bg-raised px-4 py-3 font-mono text-code whitespace-pre text-muted">
			{body.content}
		</pre>
	);
}

function Workings({
	parts,
	openToolCallIds,
	contextualToolCallId,
}: {
	parts: DynamicToolUIPart[];
	openToolCallIds?: string[];
	/**
	 * The just-landed edit's toolCallId (see ledger.ts's contextualOpenToolCallId).
	 * Folded into the row's key, not just `defaultOpen`: once a newer part makes
	 * this call no longer contextual, the key changes and the row remounts
	 * collapsed — `defaultOpen` alone only applies on a row's first mount, so it
	 * can't express "open now, auto-collapse later" on its own.
	 */
	contextualToolCallId?: string;
}) {
	return (
		<div className="my-[26px] space-y-[2px] py-1">
			{parts.map((part) => {
				const row = describeToolPart(part);
				const isContextual = part.toolCallId === contextualToolCallId;
				return (
					<ToolLedgerRow
						key={`${part.toolCallId}-${isContextual}`}
						verb={row.verb}
						subject={row.subject}
						meta={row.meta && <LedgerMetaView meta={row.meta} />}
						defaultOpen={isContextual || openToolCallIds?.includes(part.toolCallId)}
					>
						{row.body && <LedgerBodyView body={row.body} />}
					</ToolLedgerRow>
				);
			})}
		</div>
	);
}

// --- the message ----------------------------------------------------------------

export interface MessageProps {
	message: FolioMessage;
	/** Tool calls whose ledger rows start expanded (e.g. the landed test run). */
	openToolCallIds?: string[];
	animationDelay?: number;
}

export function Message({
	message,
	openToolCallIds,
	animationDelay,
}: MessageProps) {
	const isUser = message.role === "user";
	const meta = message.metadata;
	// Variation B: inside a turn frame, the user's message is the anchor at the
	// top — weightier prose closed by a hairline divider that sets it apart from
	// the agent's response beneath, so the container reads as one "turn" thing.
	if (isUser) {
		return (
			<MessageArticle
				role="user"
				author={meta?.author ?? "You"}
				stamp={meta?.stamp}
				focal={meta?.focal}
				recede={meta?.recede}
				animationDelay={animationDelay}
			>
				<div className="border-b border-line pb-[18px] font-medium text-user-ink [&_p+p]:mt-3">
					{message.parts.map((part, pi) =>
						part.type === "text"
							? part.text.split(/\n{2,}/).map((paragraph, i) => (
									<p key={`u-${pi}-${i}`}>
										<InlineMarkdown text={paragraph} />
									</p>
								))
							: null,
					)}
				</div>
			</MessageArticle>
		);
	}
	const contextualToolCallId = contextualOpenToolCallId(message.parts);
	return (
		<MessageArticle
			role="assistant"
			author={meta?.author ?? "Agent"}
			stamp={meta?.stamp}
			focal={meta?.focal}
			recede={meta?.recede}
			animationDelay={animationDelay}
		>
			{groupParts(message.parts).map((segment) => {
				if (segment.kind === "reasoning")
					return (
						<Reasoning key={segment.key} isStreaming={segment.streaming}>
							<ReasoningTrigger />
							<ReasoningContent>{segment.text}</ReasoningContent>
						</Reasoning>
					);
				if (segment.kind === "tools")
					return (
						<Workings
							key={segment.key}
							parts={segment.parts}
							openToolCallIds={openToolCallIds}
							contextualToolCallId={contextualToolCallId}
						/>
					);
				return segment.text.split(/\n{2,}/).map((paragraph, i) => (
					<p key={`${segment.key}-${i}`} className={isUser ? "text-user-ink" : ""}>
						<InlineMarkdown text={paragraph} />
					</p>
				));
			})}
			{meta?.turnStats && <TurnStatsReceipt stats={meta.turnStats} />}
		</MessageArticle>
	);
}
