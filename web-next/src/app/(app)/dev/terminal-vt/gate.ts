/** The bench exists on the dev server, or in a production build started with WEB_NEXT_TERMINAL_VT_BENCH=1. */
export function terminalVtBenchEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
	return env.NODE_ENV !== "production" || env.WEB_NEXT_TERMINAL_VT_BENCH === "1";
}
