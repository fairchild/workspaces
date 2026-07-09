import { describe, expect, test } from "vitest";
import { deriveTurnError, deriveTurnStats } from "../transcript/turn-stats";
import {
	MOCK_PROVISION_ERROR_TEXT,
	MOCK_PROVISION_ERROR_TRIGGER,
	MOCK_SANDBOX_DIED_TEXT,
	MOCK_SANDBOX_DIED_TRIGGER,
	MOCK_APPROVAL_TRIGGER,
	MOCK_STREAM_ERROR_TEXT,
	MOCK_STREAM_ERROR_TRIGGER,
	MOCK_TURN_ERROR_TRIGGER,
	mockCodingTurn,
	mockProvider,
} from "./mock-provider";
import { DEFAULT_MODEL } from "./models";
import type { TurnRepo } from "./provider";
import type { StreamChunk } from "./stream-chunk";

/** The whole scripted turn, without waiting out the streaming pace. */
async function fullTurn(
	userMessage: string,
	model?: string,
	repo?: TurnRepo | null,
): Promise<StreamChunk[]> {
	const chunks: StreamChunk[] = [];
	for await (const chunk of mockCodingTurn(
		userMessage,
		() => Promise.resolve(),
		model,
		repo,
	)) {
		chunks.push(chunk);
	}
	return chunks;
}

describe("mockCodingTurn", () => {
	test("echoes the user message in the opening prose", async () => {
		const chunks = await fullTurn("Fix the flaky retry");
		const prose = chunks
			.filter((chunk) => chunk.type === "text")
			.map((chunk) => chunk.content)
			.join("");
		expect(prose).toContain('You asked: "Fix the flaky retry"');
	});

	test("thinks first: a reasoning trace leads, before any prose or tool", async () => {
		const chunks = await fullTurn("go");
		const reasoning = chunks
			.filter((chunk) => chunk.type === "reasoning")
			.map((chunk) => chunk.content)
			.join("");
		expect(reasoning).toContain("SessionNotFoundError");
		// The thinking block precedes the visible answer and the first tool call.
		const firstReasoning = chunks.findIndex((c) => c.type === "reasoning");
		const firstText = chunks.findIndex((c) => c.type === "text");
		const firstTool = chunks.findIndex((c) => c.type === "tool_use");
		expect(firstReasoning).toBeGreaterThanOrEqual(0);
		expect(firstReasoning).toBeLessThan(firstText);
		expect(firstReasoning).toBeLessThan(firstTool);
	});

	test("reproduces (failing), fixes, then re-runs (passing)", async () => {
		const chunks = await fullTurn("go");
		const calls = chunks.filter((chunk) => chunk.type === "tool_use");
		expect(calls.map((chunk) => chunk.metadata?.toolName)).toEqual([
			"Bash",
			"Read",
			"Edit",
			"Bash",
		]);
		const results = chunks.filter((chunk) => chunk.type === "tool_result");
		expect(results).toHaveLength(4);
		// The first test run fails; the run after the edit passes.
		const failed = results.filter((chunk) => chunk.metadata?.isError === true);
		expect(failed).toHaveLength(1);
		// Each tool announces itself as a status first (the activity line).
		const statuses = chunks
			.filter((chunk) => chunk.type === "status")
			.map((chunk) => chunk.content);
		expect(statuses).toContain("Reading `src/lib/session.ts`");
		expect(statuses).toContain("Running `pnpm test session`");
	});

	test("the Edit result carries the landed diff", async () => {
		const chunks = await fullTurn("go");
		const editResult = chunks.find(
			(chunk) =>
				chunk.type === "tool_result" && chunk.metadata?.toolUseId === "tool-3",
		);
		expect(editResult?.metadata?.diff).toMatchObject({
			file: "src/lib/session.ts",
			additions: 3,
			deletions: 1,
		});
	});

	test("the turn derives a complete receipt", async () => {
		const chunks = await fullTurn("go");
		const stats = deriveTurnStats(chunks);
		expect(stats).toMatchObject({
			toolCount: 4,
			filesChanged: 1,
			additions: 3,
			deletions: 1,
			testsPassed: 4,
		});
		expect(stats?.tokenCount).toBeGreaterThan(0);
	});

	test("the provider registers as `mock` and runs the scripted turn", async () => {
		expect(mockProvider.id).toBe("mock");
		const iterator = mockProvider.runTurn({
			sessionId: "s",
			userMessage: "hi",
		})[Symbol.asyncIterator]();
		const first = await iterator.next();
		expect(first.value).toEqual({ type: "status", content: "Starting sandbox" });
		await iterator.return?.(undefined);
	});

	test("records the default model on the terminal done chunk when none is requested (#824)", async () => {
		const chunks = await fullTurn("go");
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.model).toBe(DEFAULT_MODEL);
	});

	test("records an explicit model override on the terminal done chunk (#824)", async () => {
		const chunks = await fullTurn("go", "claude-haiku-4-5");
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.model).toBe("claude-haiku-4-5");
	});

	test("records the requested repo on the terminal done chunk (#967)", async () => {
		const repo = {
			fullName: "fairchild/web-next-fixtures",
			defaultBranch: "trunk",
		};
		const chunks = await fullTurn("go", undefined, repo);
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.repo).toEqual(repo);
	});

	test("also records a plausible contextTokens figure alongside tokenCount", async () => {
		const chunks = await fullTurn("go");
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.contextTokens).toBeGreaterThan(0);
	});

	test("approval scenario emits request, waits for the broker result, then continues", async () => {
		const chunks: StreamChunk[] = [];
		for await (const chunk of mockCodingTurn(
			`go ${MOCK_APPROVAL_TRIGGER}`,
			() => Promise.resolve(),
			undefined,
			undefined,
			async (input) => ({
				requestId: "approval-1",
				toolName: input.toolName,
				inputSummary: input.inputSummary,
				requestedAt: "2026-07-08T12:00:00.000Z",
				expiresAt: "2026-07-08T12:01:00.000Z",
				resolution: Promise.resolve({
					requestId: "approval-1",
					decision: "allow",
					resolvedBy: "user",
					decidedAt: "2026-07-08T12:00:05.000Z",
				}),
			}),
		)) {
			chunks.push(chunk);
		}

		expect(chunks).toContainEqual({
			type: "approval_request",
			content: "Claude wants to edit src/lib/session.ts.",
			metadata: {
				requestId: "approval-1",
				toolName: "Edit",
				inputSummary:
					"Edit src/lib/session.ts to add a missing SessionNotFoundError guard.",
				expiresAt: "2026-07-08T12:01:00.000Z",
			},
		});
		expect(chunks).toContainEqual({
			type: "approval_resolved",
			content: "allow",
			metadata: {
				requestId: "approval-1",
				decision: "allow",
				resolvedBy: "user",
			},
		});
		expect(chunks.some((chunk) => chunk.type === "tool_use")).toBe(true);
		expect(chunks.at(-1)?.type).toBe("done");
	});

	describe("MOCK_TURN_ERROR_TRIGGER (#808)", () => {
		test("throws instead of running the script when the trigger is present", async () => {
			const iterator = mockCodingTurn(
				`please fix it ${MOCK_TURN_ERROR_TRIGGER}`,
				() => Promise.resolve(),
			)[Symbol.asyncIterator]();
			// One status chunk (realistic provisioning) precedes the failure.
			const first = await iterator.next();
			expect(first.value).toEqual({ type: "status", content: "Starting sandbox" });
			await expect(iterator.next()).rejects.toThrow(
				"Simulated turn failure (mock provider)",
			);
		});

		test("a message without the trigger runs the normal script unaffected", async () => {
			const chunks = await fullTurn(`no trigger here`);
			expect(chunks.some((chunk) => chunk.type === "error")).toBe(false);
			expect(chunks.at(-1)).toMatchObject({ type: "done" });
		});

		test("mockProvider.runTurn fails once per session, then succeeds on retry", async () => {
			// mockProvider.runTurn (unlike fullTurn's injectable sleep) paces with
			// the real scripted delays, so this only reads the first couple of
			// chunks of each run — enough to prove which path it took — rather
			// than draining the whole ~9s script.
			const sessionId = `s-${crypto.randomUUID()}`;
			const text = `Fix it ${MOCK_TURN_ERROR_TRIGGER}`;

			// First turn against this session: the trigger fires.
			const first = mockProvider
				.runTurn({ sessionId, userMessage: text })
				[Symbol.asyncIterator]();
			await expect(first.next()).resolves.toEqual({
				value: { type: "status", content: "Starting sandbox" },
				done: false,
			});
			await expect(first.next()).rejects.toThrow(
				"Simulated turn failure (mock provider)",
			);

			// A retry re-sending the identical text against the SAME session
			// succeeds — the trigger is spent (#808's e2e "retry succeeds" case):
			// the second status chunk (only reachable past the would-be throw)
			// proves the normal script ran instead of failing again.
			const retry = mockProvider
				.runTurn({ sessionId, userMessage: text })
				[Symbol.asyncIterator]();
			await retry.next();
			await expect(retry.next()).resolves.toEqual({
				value: { type: "status", content: "Cloning repo" },
				done: false,
			});
			await retry.return?.(undefined);

			// A DIFFERENT session with the same text still gets its own guaranteed
			// failure — the gate is per-session, not global.
			const other = mockProvider
				.runTurn({ sessionId: `s-${crypto.randomUUID()}`, userMessage: text })
				[Symbol.asyncIterator]();
			await other.next();
			await expect(other.next()).rejects.toThrow(
				"Simulated turn failure (mock provider)",
			);
		});
	});

	describe("error-class triggers (#753)", () => {
		test("provisioning failure: throws before ANY content chunk streams", async () => {
			const iterator = mockCodingTurn(
				`build it ${MOCK_PROVISION_ERROR_TRIGGER}`,
				() => Promise.resolve(),
			)[Symbol.asyncIterator]();
			const first = await iterator.next();
			expect(first.value).toEqual({ type: "status", content: "Starting sandbox" });
			await expect(iterator.next()).rejects.toThrow(MOCK_PROVISION_ERROR_TEXT);
		});

		test("sandbox died: fails mid-turn, AFTER prose and a tool call landed", async () => {
			const chunks: StreamChunk[] = [];
			const turn = mockCodingTurn(
				`build it ${MOCK_SANDBOX_DIED_TRIGGER}`,
				() => Promise.resolve(),
			);
			await expect(async () => {
				for await (const chunk of turn) chunks.push(chunk);
			}).rejects.toThrow(MOCK_SANDBOX_DIED_TEXT);
			// The work streamed before the VM died is real and precedes the failure.
			expect(chunks.some((chunk) => chunk.type === "text")).toBe(true);
			expect(chunks.some((chunk) => chunk.type === "tool_result")).toBe(true);
		});

		test("stream error: an `error` CHUNK mid-stream, ending without `done`", async () => {
			const chunks: StreamChunk[] = [];
			for await (const chunk of mockCodingTurn(
				`build it ${MOCK_STREAM_ERROR_TRIGGER}`,
				() => Promise.resolve(),
			)) {
				chunks.push(chunk);
			}
			// Prose streamed first; the structured error chunk closes the stream.
			expect(chunks.some((chunk) => chunk.type === "text")).toBe(true);
			expect(chunks.at(-1)).toEqual({
				type: "error",
				content: MOCK_STREAM_ERROR_TEXT,
			});
			expect(chunks.some((chunk) => chunk.type === "done")).toBe(false);
			// deriveTurnError tags the turn from the chunk — the same read both the
			// projection and the live receipt path use.
			expect(deriveTurnError(chunks)).toBe(MOCK_STREAM_ERROR_TEXT);
		});

		test("each trigger spends independently on the same session", async () => {
			const sessionId = `s-${crypto.randomUUID()}`;

			// Spend the provisioning trigger…
			const provision = mockProvider
				.runTurn({
					sessionId,
					userMessage: `go ${MOCK_PROVISION_ERROR_TRIGGER}`,
				})
				[Symbol.asyncIterator]();
			await provision.next();
			await expect(provision.next()).rejects.toThrow(MOCK_PROVISION_ERROR_TEXT);

			// …the generic trigger (also unspent, also failing at the same early
			// point) still gets ITS guaranteed failure on this session.
			const generic = mockProvider
				.runTurn({ sessionId, userMessage: `go ${MOCK_TURN_ERROR_TRIGGER}` })
				[Symbol.asyncIterator]();
			await generic.next();
			await expect(generic.next()).rejects.toThrow(
				"Simulated turn failure (mock provider)",
			);

			// And a provisioning retry (that trigger already spent) runs the script.
			const retry = mockProvider
				.runTurn({
					sessionId,
					userMessage: `go ${MOCK_PROVISION_ERROR_TRIGGER}`,
				})
				[Symbol.asyncIterator]();
			await retry.next();
			await expect(retry.next()).resolves.toEqual({
				value: { type: "status", content: "Cloning repo" },
				done: false,
			});
			await retry.return?.(undefined);
		});
	});
});
