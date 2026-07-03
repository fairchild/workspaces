/*
 * Test-output panel: command output rendered as the workings' quiet code
 * block, with pass marks and "N passed" counts gently highlighted.
 * Structured props so #748 can pipe real runner output straight in.
 */
import { highlightTestOutput } from "./ledger";

const TONE_CLASS = {
	plain: undefined,
	ok: "text-add-ink",
	fail: "text-del-ink",
	strong: "font-medium text-ink",
} as const;

export interface TestOutputPanelProps {
	output: string;
	passed: boolean;
}

export function TestOutputPanel({ output, passed }: TestOutputPanelProps) {
	return (
		<pre
			data-testid="test-output"
			data-passed={passed}
			className="overflow-x-auto rounded-lg border border-line bg-raised px-4 py-3 font-mono text-code whitespace-pre text-muted"
		>
			{highlightTestOutput(output).map((segments, lineIndex) => (
				<span key={lineIndex}>
					{lineIndex > 0 && "\n"}
					{segments.map((segment, i) =>
						TONE_CLASS[segment.tone] === undefined ? (
							segment.text
						) : (
							<span key={i} className={TONE_CLASS[segment.tone]}>
								{segment.text}
							</span>
						),
					)}
				</span>
			))}
		</pre>
	);
}
