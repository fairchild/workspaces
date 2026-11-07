/** The spike harness exists on the dev server, or in a production build started with WEB_NEXT_TERMINAL_VT_SPIKE=1. */
export function terminalVtSpikeEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
	return env.NODE_ENV !== "production" || env.WEB_NEXT_TERMINAL_VT_SPIKE === "1";
}
