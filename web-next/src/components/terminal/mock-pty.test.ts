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
	function attach() {
		const chunks: string[] = [];
		const conn = openMockPty({
			onData: (text) => chunks.push(text),
			onClose: () => {},
		});
		return { conn, output: () => chunks.join("") };
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

	test("a closed connection emits nothing further", () => {
		const { conn, output } = attach();
		const before = output();
		conn.close();
		conn.send("echo after\r");
		expect(output()).toBe(before);
	});
});
