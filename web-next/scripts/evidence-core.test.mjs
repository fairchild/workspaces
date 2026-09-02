import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { EventEmitter } from "node:events";
import { describe, expect, test, vi } from "vitest";
import {
	createRunDeadline,
	describeMissingCaptures,
	ERROR_SURFACE_CASES,
	EXPECTED_CAPTURE_NAMES,
	expectedCaptureFiles,
	findMissingCaptures,
	installCompletionLatch,
	THEMES,
} from "./evidence-core.mjs";

const SCRIPTS_DIR = path.dirname(fileURLToPath(import.meta.url));

describe("capture manifest", () => {
	test("covers every capture the walk takes, and no capture it doesn't", () => {
		const source = readFileSync(
			path.join(SCRIPTS_DIR, "evidence.mjs"),
			"utf8",
		);
		const literals = [...source.matchAll(/shot\("([^"]+)"\)/g)].map(
			([, name]) => name,
		);
		const walked = new Set([
			...literals,
			...ERROR_SURFACE_CASES.map(([name]) => name),
		]);

		expect(walked.size).toBeGreaterThan(0);
		expect([...walked].sort()).toEqual([...EXPECTED_CAPTURE_NAMES].sort());
	});

	test("expands to one file per capture per theme", () => {
		const files = expectedCaptureFiles();

		expect(files).toHaveLength(EXPECTED_CAPTURE_NAMES.length * THEMES.length);
		expect(files).toContain("home-empty-light.png");
		expect(files).toContain("prototype-folio-dark.png");
		expect(new Set(files).size).toBe(files.length);
	});
});

describe("completion check", () => {
	const expected = ["a-light.png", "b-light.png"];

	test("a run that wrote nothing is missing everything", () => {
		expect(findMissingCaptures(expected, new Map())).toEqual([
			{ file: "a-light.png", reason: "never written" },
			{ file: "b-light.png", reason: "never written" },
		]);
	});

	test("a half-finished walk fails on what it never reached", () => {
		const missing = findMissingCaptures(
			expected,
			new Map([["a-light.png", 4096]]),
		);

		expect(missing).toEqual([{ file: "b-light.png", reason: "never written" }]);
	});

	test("an empty file does not count as a capture", () => {
		const missing = findMissingCaptures(
			expected,
			new Map([
				["a-light.png", 4096],
				["b-light.png", 0],
			]),
		);

		expect(missing).toEqual([{ file: "b-light.png", reason: "written empty" }]);
	});

	test("a complete walk has nothing missing", () => {
		const sizes = new Map(expected.map((file) => [file, 4096]));

		expect(findMissingCaptures(expected, sizes)).toEqual([]);
	});

	test("extra files from an unrelated run do not satisfy the manifest", () => {
		const missing = findMissingCaptures(
			expected,
			new Map([
				["a-light.png", 4096],
				["something-else.png", 4096],
			]),
		);

		expect(missing).toEqual([{ file: "b-light.png", reason: "never written" }]);
	});

	test("the failure names the count, the files, and why they failed", () => {
		const message = describeMissingCaptures(
			"/out",
			[
				{ file: "a-light.png", reason: "never written" },
				{ file: "b-light.png", reason: "written empty" },
			],
			2,
		);

		expect(message).toContain("0/2 captures in /out");
		expect(message).toContain("a-light.png — never written");
		expect(message).toContain("b-light.png — written empty");
	});

	test("a long list of missing captures is elided rather than dumped", () => {
		const missing = Array.from({ length: 20 }, (_, i) => ({
			file: `c${i}-light.png`,
			reason: "never written",
		}));

		const message = describeMissingCaptures("/out", missing, 20);

		expect(message).toContain("…and 8 more");
		expect(message).not.toContain("c19-light.png");
	});
});

describe("run deadline", () => {
	test("rejects with the budget and the escape hatch when the run overruns", async () => {
		vi.useFakeTimers();
		try {
			const deadline = createRunDeadline(1_000);
			const settled = expect(deadline.expired).rejects.toThrow(
				/exceeded 1000ms.*EVIDENCE_TIMEOUT_MS/s,
			);
			await vi.advanceTimersByTimeAsync(1_000);
			await settled;
		} finally {
			vi.useRealTimers();
		}
	});

	test("holds a real timer so the event loop cannot empty mid-run", () => {
		const setTimeoutSpy = vi.fn().mockReturnValue("timer-handle");
		const clearTimeoutSpy = vi.fn();

		const deadline = createRunDeadline(5_000, {
			timers: { setTimeout: setTimeoutSpy, clearTimeout: clearTimeoutSpy },
		});

		expect(setTimeoutSpy).toHaveBeenCalledWith(expect.any(Function), 5_000);
		deadline.cancel();
		expect(clearTimeoutSpy).toHaveBeenCalledWith("timer-handle");
	});
});

describe("completion latch", () => {
	/** Stands in for `process`: an emitter carrying a settable exitCode. */
	const fakeProcess = () => Object.assign(new EventEmitter(), { exitCode: 0 });

	test("turns a silent exit-0 into a failure", () => {
		const proc = fakeProcess();
		const log = vi.fn();
		installCompletionLatch({ proc, log });

		proc.emit("exit", 0);

		expect(proc.exitCode).toBe(1);
		expect(log).toHaveBeenCalledOnce();
		expect(log.mock.calls[0][0]).toMatch(/without finishing the walk/i);
	});

	test("leaves a completed run alone", () => {
		const proc = fakeProcess();
		const log = vi.fn();
		const latch = installCompletionLatch({ proc, log });

		latch.markCompleted();
		proc.emit("exit", 0);

		expect(proc.exitCode).toBe(0);
		expect(log).not.toHaveBeenCalled();
	});

	test("does not relabel a run that already failed loudly", () => {
		const proc = fakeProcess();
		const log = vi.fn();
		installCompletionLatch({ proc, log });

		proc.emit("exit", 1);

		expect(proc.exitCode).toBe(0);
		expect(log).not.toHaveBeenCalled();
	});
});
