/*
 * /sessions/demo — the Folio design system rendered from fixture data, no
 * backend. `?seed=<n>` swaps in a generated n-message transcript for the
 * transcript_render_200 perf scenario.
 */
import { SessionView } from "@/components/folio/session-view";
import { demoSession, seededDemoSession } from "@/lib/fixtures/demo-session";

export default async function DemoSessionPage({
	searchParams,
}: {
	searchParams: Promise<{ seed?: string }>;
}) {
	const { seed } = await searchParams;
	const seedCount = Number(seed);
	const session =
		Number.isInteger(seedCount) && seedCount > 0
			? seededDemoSession(seedCount)
			: demoSession();
	return <SessionView session={session} />;
}
