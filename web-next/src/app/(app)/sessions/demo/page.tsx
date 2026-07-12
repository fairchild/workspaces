/*
 * /sessions/demo — the Folio design system rendered from fixture data, no
 * backend. `?seed=<n>` swaps in a generated n-message transcript for the
 * transcript_render_200 perf scenario; `?scenario=adversarial` renders one
 * worst-case turn (long reasoning, 16 tools, a 100+ line diff, a failure) and
 * `?scenario=long` a 15+ turn session for reviewing the frame at scale.
 */
import { SessionView } from "@fairchild/folio";
import {
	adversarialSession,
	demoSession,
	longTranscriptSession,
	seededDemoSession,
} from "@/lib/fixtures/demo-session";

function pickSession(scenario: string | undefined, seed: string | undefined) {
	if (scenario === "adversarial") return adversarialSession();
	if (scenario === "long") return longTranscriptSession();
	const seedCount = Number(seed);
	if (Number.isInteger(seedCount) && seedCount > 0) {
		return seededDemoSession(seedCount);
	}
	return demoSession();
}

export default async function DemoSessionPage({
	searchParams,
}: {
	searchParams: Promise<{ seed?: string; scenario?: string }>;
}) {
	const { seed, scenario } = await searchParams;
	return <SessionView session={pickSession(scenario, seed)} />;
}
