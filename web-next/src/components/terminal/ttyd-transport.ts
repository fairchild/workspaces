/*
 * The real terminal transport (#752): a WebSocket speaking ttyd's protocol to
 * the shell in the session's sandbox. Binary frames, first byte the command:
 * server→client '0' = output; client→server '0' = input, '1' = resize JSON.
 * The opening message is ttyd's JSON handshake ({AuthToken, columns, rows} —
 * auth is the HMAC base-path in the URL, so the token field stays empty).
 * Ported from web/'s terminal-canvas wiring.
 */
import type {
	TerminalConnection,
	TerminalTransportHandlers,
} from "./transport";

export function openTtydSocket(
	wsUrl: string,
	handlers: TerminalTransportHandlers,
	size: { cols: number; rows: number },
): TerminalConnection {
	const ws = new WebSocket(wsUrl, ["tty"]);
	ws.binaryType = "arraybuffer";
	const encoder = new TextEncoder();
	const decoder = new TextDecoder();

	const frame = (command: string, payload: string): Uint8Array => {
		const bytes = encoder.encode(payload);
		const out = new Uint8Array(bytes.length + 1);
		out[0] = command.charCodeAt(0);
		out.set(bytes, 1);
		return out;
	};

	ws.onopen = () => {
		ws.send(
			JSON.stringify({ AuthToken: "", columns: size.cols, rows: size.rows }),
		);
	};
	ws.onmessage = (event) => {
		if (!(event.data instanceof ArrayBuffer)) return;
		const data = new Uint8Array(event.data);
		if (data.length === 0) return;
		if (String.fromCharCode(data[0]) === "0") {
			handlers.onData(decoder.decode(data.subarray(1)));
		}
	};
	ws.onclose = () => handlers.onClose("disconnected");
	ws.onerror = () => handlers.onClose("connection error");

	return {
		send(data: string) {
			if (ws.readyState === WebSocket.OPEN) ws.send(frame("0", data));
		},
		resize(cols: number, rows: number) {
			if (ws.readyState === WebSocket.OPEN)
				ws.send(frame("1", JSON.stringify({ columns: cols, rows })));
		},
		close() {
			ws.onclose = null;
			ws.onerror = null;
			ws.close();
		},
	};
}
