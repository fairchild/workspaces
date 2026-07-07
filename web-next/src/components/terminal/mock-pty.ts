/*
 * Deterministic in-browser PTY sim (#752): the transport behind the drawer
 * under AUTH_BYPASS, so Playwright e2e and the perf gate exercise the real
 * drawer + terminal rendering with no sandbox. Local echo, line editing
 * (backspace), and a tiny fixed command set — no clock, no randomness, so
 * every run paints identical bytes. `evalMockCommand` is pure and exported
 * for unit tests.
 */
import type {
	TerminalConnection,
	TerminalTransportHandlers,
} from "./transport";

export const MOCK_PROMPT = "sandbox:workspace$ ";
const MOCK_BANNER = "mock sandbox shell — deterministic PTY (AUTH_BYPASS)";

const MOCK_LS = [
	"README.md   package.json   src   tests",
];

/** The output lines for one entered command line. Pure and deterministic. */
export function evalMockCommand(line: string): string[] {
	const trimmed = line.trim();
	if (trimmed.length === 0) return [];
	const [cmd, ...args] = trimmed.split(/\s+/);
	switch (cmd) {
		case "echo":
			return [args.join(" ")];
		case "pwd":
			return ["/vercel/sandbox/workspace"];
		case "ls":
			return MOCK_LS;
		case "whoami":
			return ["sandbox"];
		case "help":
			return ["mock shell commands: echo, pwd, ls, whoami, help, clear"];
		default:
			return [`sh: ${cmd}: command not found`];
	}
}

export function openMockPty(
	handlers: TerminalTransportHandlers,
): TerminalConnection {
	let line = "";
	let closed = false;
	const write = (text: string) => {
		if (!closed) handlers.onData(text);
	};

	// The first paint: banner + prompt, synchronously on open.
	write(`\x1b[2m${MOCK_BANNER}\x1b[0m\r\n${MOCK_PROMPT}`);

	const run = () => {
		const entered = line;
		line = "";
		if (entered.trim() === "clear") {
			write(`\x1b[2J\x1b[H${MOCK_PROMPT}`);
			return;
		}
		const output = evalMockCommand(entered);
		const body = output.length > 0 ? `${output.join("\r\n")}\r\n` : "";
		write(`\r\n${body}${MOCK_PROMPT}`);
	};

	return {
		send(data: string) {
			for (const ch of data) {
				if (ch === "\r" || ch === "\n") {
					run();
				} else if (ch === "\x7f" || ch === "\b") {
					if (line.length > 0) {
						line = line.slice(0, -1);
						write("\b \b");
					}
				} else if (ch === "\x03") {
					// Ctrl-C: drop the line, fresh prompt.
					line = "";
					write(`^C\r\n${MOCK_PROMPT}`);
				} else if (ch >= " ") {
					line += ch;
					write(ch);
				}
			}
		},
		resize() {
			// The sim has no PTY to resize; deterministic output ignores size.
		},
		close() {
			closed = true;
		},
	};
}
