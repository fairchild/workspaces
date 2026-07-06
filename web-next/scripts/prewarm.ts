/*
 * Local driver for prewarmVercelTemplate(): builds (or refreshes) the harness
 * sandbox template and prints how long it took. Run it twice to confirm the
 * second call is a fast idempotent no-op — the reuse guarantee runTurn depends on.
 *
 *   HARNESS_DEBUG=1 node --env-file=.env.local --import tsx scripts/prewarm.ts
 */
import { prewarmVercelTemplate } from "../src/lib/agent-runtime/vercel-provider";

async function main() {
	const started = Date.now();
	console.log("[prewarm] building/refreshing template…");
	const { tookMs } = await prewarmVercelTemplate();
	console.log(
		`[prewarm] done in ${(tookMs / 1000).toFixed(1)}s (wall ${((Date.now() - started) / 1000).toFixed(1)}s)`,
	);
}

main().catch((err) => {
	console.error("[prewarm] fatal:", err);
	process.exit(1);
});
