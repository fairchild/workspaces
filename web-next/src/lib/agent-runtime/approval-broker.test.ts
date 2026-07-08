import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import { createSession } from "../db/sessions";
import {
	answerApproval,
	beginApprovalRequest,
	getApprovalRequest,
	requestApproval,
} from "./approval-broker";

let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-approvals-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

describe("approval broker", () => {
	test("resolves from the answer endpoint path", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		const pending = await beginApprovalRequest(handle, {
			sessionId: "s1",
			toolName: "Edit",
			inputSummary: "Edit a.ts",
			timeoutMs: 1000,
			pollIntervalMs: 20,
		});

		const answer = await answerApproval(handle, {
			sessionId: "s1",
			requestId: pending.requestId,
			decision: "allow",
		});

		expect(answer.status).toBe("resolved");
		await expect(pending.resolution).resolves.toMatchObject({
			requestId: pending.requestId,
			decision: "allow",
			resolvedBy: "user",
		});
	});

	test("times out as deny/timeout", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		const resolution = requestApproval(handle, {
			sessionId: "s1",
			toolName: "Bash",
			inputSummary: "pnpm test",
			timeoutMs: 1,
			pollIntervalMs: 5,
		});

		await expect(resolution).resolves.toMatchObject({
			decision: "deny",
			resolvedBy: "timeout",
		});
	});

	test("abort resolves as deny/abort and persists the row", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		const controller = new AbortController();
		const pending = await beginApprovalRequest(handle, {
			sessionId: "s1",
			toolName: "Write",
			inputSummary: "Write generated.txt",
			timeoutMs: 10_000,
			pollIntervalMs: 20,
			signal: controller.signal,
		});

		controller.abort();

		await expect(pending.resolution).resolves.toMatchObject({
			decision: "deny",
			resolvedBy: "abort",
		});
		const row = await getApprovalRequest(handle, "s1", pending.requestId);
		expect(row).toMatchObject({ decision: "deny", decided_by: "abort" });
	});

	test("polling catches a decision written without an in-process notify", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		const pending = await beginApprovalRequest(handle, {
			sessionId: "s1",
			toolName: "Edit",
			inputSummary: "Edit b.ts",
			timeoutMs: 1000,
			pollIntervalMs: 5,
		});
		const decidedAt = new Date().toISOString();

		await handle.db
			.updateTable("turn_approvals")
			.set({ decision: "deny", decided_at: decidedAt, decided_by: "user" })
			.where("session_id", "=", "s1")
			.where("request_id", "=", pending.requestId)
			.execute();

		await expect(pending.resolution).resolves.toMatchObject({
			requestId: pending.requestId,
			decision: "deny",
			resolvedBy: "user",
		});
	});
});
