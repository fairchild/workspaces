/*
 * /dev/terminal-vt — the #1846 spike harness: ghostty-web 0.4.0 and Ghostty's
 * release libghostty-vt 1.0 wasm side by side, fed the same bytes. Gated by
 * terminalVtSpikeEnabled; a 404 everywhere else.
 */
import { notFound } from "next/navigation";
import { terminalVtSpikeEnabled } from "./gate";
import { TerminalVtSpike } from "./terminal-vt-spike";

export default function TerminalVtSpikePage() {
	if (!terminalVtSpikeEnabled()) notFound();
	return <TerminalVtSpike />;
}
