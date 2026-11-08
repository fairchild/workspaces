/*
 * /dev/terminal-vt — the bench for the drawer's terminal: the canvas over
 * Ghostty's release libghostty-vt wasm, fed a recorded fixture, the mock
 * PTY, a live ttyd WebSocket, a stress stream, or the parity screen the e2e
 * spec drives. Gated by terminalVtBenchEnabled; a 404 everywhere else.
 */
import { notFound } from "next/navigation";
import { terminalVtBenchEnabled } from "./gate";
import { TerminalVtBench } from "./terminal-vt-bench";

export default function TerminalVtBenchPage() {
	if (!terminalVtBenchEnabled()) notFound();
	return <TerminalVtBench />;
}
