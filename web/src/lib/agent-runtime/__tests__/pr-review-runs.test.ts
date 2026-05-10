import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Use a unique in-memory libsql DB per test process so the schema bootstrap
// runs against a real engine without persisting between runs.
beforeEach(() => {
	vi.stubEnv("TURSO_DATABASE_URL", ":memory:");
});

afterEach(() => {
	vi.unstubAllEnvs();
	vi.resetModules();
});

async function loadModule() {
	vi.resetModules();
	const mod = await import("../pr-review-runs");
	mod.__resetPrReviewRunsForTests();
	return mod;
}

interface RunInput {
	fingerprint: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
	reviewerConfigHash: string;
}

function makeInput(overrides: Partial<RunInput> = {}): RunInput {
	return {
		fingerprint: "fp_unit_test",
		repoFullName: "fairchild/workspaces",
		prNumber: 1,
		headSha: "abc123",
		triggerKind: "synchronize",
		triggerSourceId: "abc123",
		reviewerConfigHash: "cfg",
		...overrides,
	};
}

describe("recordRunStart", () => {
	it("inserts on first call and skips a fresh duplicate", async () => {
		const { recordRunStart } = await loadModule();
		const input = makeInput();

		const first = await recordRunStart(input);
		expect(first.inserted).toBe(true);

		const second = await recordRunStart(input);
		expect(second.inserted).toBe(false);
	});

	it("treats a completed prior run as a permanent skip", async () => {
		const { recordRunStart, recordRunResult } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);
		await recordRunResult(input.fingerprint, {
			sessionId: "sesn_done",
			status: "completed",
		});

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(false);
		expect(retry.priorStatus).toBe("completed");
	});

	it("retries when the prior run failed", async () => {
		const { recordRunStart, recordRunResult } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);
		await recordRunResult(input.fingerprint, {
			sessionId: null,
			status: "failed",
			error: "session denied",
		});

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(true);
		expect(retry.priorStatus).toBe("failed");
	});

	it("retries when a prior `started` row is stale (likely crashed)", async () => {
		const { recordRunStart } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);

		// Force the row's updated_at to be older than the stale threshold.
		const { getDb } = await import("../../db");
		const oldStamp = new Date(Date.now() - 30 * 60 * 1000).toISOString();
		await getDb()
			.updateTable("managed_pr_review_runs")
			.set({ updated_at: oldStamp })
			.where("fingerprint", "=", input.fingerprint)
			.execute();

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(true);
		expect(retry.priorStatus).toBe("started");
	});
});
