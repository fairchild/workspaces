import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { openTtydSocket } from "./ttyd-transport";
import { GHOSTTY_VT_RELEASE, instantiateVt, VtTerminal } from "./vt/ghostty-vt";
import { viewportText } from "./vt/snapshot";

/** The parts of a browser WebSocket the transport touches, driven by the test. */
class FakeSocket {
	static OPEN = 1;
	static last: FakeSocket;
	readyState = 0;
	binaryType = "blob";
	sent: (string | Uint8Array)[] = [];
	onopen: (() => void) | null = null;
	onmessage: ((event: { data: unknown }) => void) | null = null;
	onclose: (() => void) | null = null;
	onerror: (() => void) | null = null;

	constructor(
		readonly url: string,
		readonly protocols: string[],
	) {
		FakeSocket.last = this;
	}
	send(data: string | Uint8Array) {
		this.sent.push(data);
	}
	close() {}
	open() {
		this.readyState = FakeSocket.OPEN;
		this.onopen?.();
	}
	/** A ttyd output frame: command byte '0', then the payload. */
	output(payload: Uint8Array) {
		const frame = new Uint8Array(payload.length + 1);
		frame[0] = "0".charCodeAt(0);
		frame.set(payload, 1);
		this.onmessage?.({ data: frame.buffer });
	}
}

const realWebSocket = globalThis.WebSocket;
beforeEach(() => {
	globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
});
afterEach(() => {
	globalThis.WebSocket = realWebSocket;
});

const encoder = new TextEncoder();
/** Cut inside 日 and inside ✅, the way ttyd frames fall on byte counts. */
const text = "echo 日本語 ✅ ok\r\n";
const bytes = encoder.encode(text);
const cuts = [7, 16, bytes.length];

function frames(socket: FakeSocket) {
	let start = 0;
	for (const end of cuts) {
		socket.output(bytes.subarray(start, end));
		start = end;
	}
}

describe("openTtydSocket", () => {
	test("hands output bytes over undecoded, frame by frame", () => {
		const received: Uint8Array[] = [];
		openTtydSocket("wss://sandbox.test/ws", { onData: (b) => received.push(b), onClose: () => {} }, { cols: 80, rows: 24 });
		const socket = FakeSocket.last;
		socket.open();
		frames(socket);
		expect(received.map((b) => b.length)).toEqual([7, 9, bytes.length - 16]);
		expect(Buffer.concat(received.map((b) => Buffer.from(b)))).toEqual(Buffer.from(bytes));
	});

	test("opens with ttyd's handshake and frames input bytes and resizes", () => {
		const conn = openTtydSocket("wss://sandbox.test/ws", { onData: () => {}, onClose: () => {} }, { cols: 80, rows: 24 });
		const socket = FakeSocket.last;
		expect(socket.protocols).toEqual(["tty"]);
		expect(socket.binaryType).toBe("arraybuffer");
		socket.open();
		conn.send(encoder.encode("ä\r"));
		conn.resize(100, 30);
		expect(socket.sent[0]).toBe(JSON.stringify({ AuthToken: "", columns: 80, rows: 24 }));
		expect([...(socket.sent[1] as Uint8Array)]).toEqual([0x30, 0xc3, 0xa4, 0x0d]);
		expect(new TextDecoder().decode(socket.sent[2] as Uint8Array)).toBe(`1${JSON.stringify({ columns: 100, rows: 30 })}`);
	});
});

const wasmPath = join(process.cwd(), "public", GHOSTTY_VT_RELEASE.servedFrom, GHOSTTY_VT_RELEASE.file);

describe.skipIf(!existsSync(wasmPath) && process.env.CI !== "true")("ttyd frames into the drawer's terminal (#1854)", () => {
	test("a character split across two frames renders whole", async () => {
		const file = readFileSync(wasmPath);
		const vt = new VtTerminal(await instantiateVt(file.buffer.slice(file.byteOffset, file.byteOffset + file.byteLength) as ArrayBuffer), {
			columns: 40,
			rows: 3,
		});
		openTtydSocket("wss://sandbox.test/ws", { onData: (b) => vt.write(b), onClose: () => {} }, { cols: 40, rows: 3 });
		const socket = FakeSocket.last;
		socket.open();
		frames(socket);
		const screen = viewportText(vt.snapshot());
		expect(screen.split("\n")[0]).toBe("echo 日本語 ✅ ok");
		expect(screen).not.toContain("�");
		vt.dispose();
	});
});
