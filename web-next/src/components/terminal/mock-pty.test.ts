import { describe, expect, test } from "vitest";
import { evalMockCommand, MOCK_PROMPT, openMockPty } from "./mock-pty";

describe("evalMockCommand", () => {
	test("is deterministic over the fixed command set", () => {
		expect(evalMockCommand("echo hello world")).toEqual(["hello world"]);
		expect(evalMockCommand("pwd")).toEqual(["/vercel/sandbox/workspace"]);
		expect(evalMockCommand("whoami")).toEqual(["sandbox"]);
		expect(evalMockCommand("")).toEqual([]);
		expect(evalMockCommand("   ")).toEqual([]);
		expect(evalMockCommand("nope --flag")).toEqual([
			"sh: nope: command not found",
		]);
	});
});

describe("openMockPty", () => {
	const encoder = new TextEncoder();

	function attach() {
		const chunks: Uint8Array[] = [];
		const pty = openMockPty({
			onData: (bytes) => chunks.push(bytes),
			onClose: () => {},
		});
		const conn = {
			send: (text: string) => pty.send(encoder.encode(text)),
			sendBytes: (bytes: Uint8Array) => pty.send(bytes),
			close: () => pty.close(),
		};
		const output = () =>
			new TextDecoder().decode(Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))));
		return { conn, output };
	}

	test("paints a banner and prompt synchronously on open", () => {
		const { output } = attach();
		expect(output()).toContain("mock sandbox shell");
		expect(output()).toContain(MOCK_PROMPT);
	});

	test("echoes keystrokes and runs the line on Enter", () => {
		const { conn, output } = attach();
		conn.send("echo hi");
		conn.send("\r");
		expect(output()).toContain("echo hi\r\nhi\r\n");
		expect(output().endsWith(MOCK_PROMPT)).toBe(true);
	});

	test("backspace edits the line", () => {
		const { conn, output } = attach();
		conn.send("pwdd");
		conn.send("\x7f");
		conn.send("\r");
		expect(output()).toContain("/vercel/sandbox/workspace");
	});

	test("joins a character whose UTF-8 bytes arrive in two sends", () => {
		const { conn, output } = attach();
		const bytes = encoder.encode("echo 日本\r");
		conn.sendBytes(bytes.subarray(0, 7));
		conn.sendBytes(bytes.subarray(7));
		expect(output()).toContain("echo 日本\r\n日本\r\n");
		expect(output()).not.toContain("\uFFFD");
	});

	test("a closed connection emits nothing further", () => {
		const { conn, output } = attach();
		const before = output();
		conn.close();
		conn.send("echo after\r");
		expect(output()).toBe(before);
	});
});
