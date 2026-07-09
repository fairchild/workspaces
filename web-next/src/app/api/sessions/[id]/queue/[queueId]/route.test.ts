/*
 * DELETE /api/sessions/[id]/queue/[queueId] — canceling durable steering rows
 * before dispatch, while refusing rows already claimed by the turn runtime.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import {
	claimNextQueuedMessage,
	enqueueMessage,
	listQueuedMessages,
} from "@/lib/db/queued-messages";
import { createSession } from "@/lib/db/sessions";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

const dir = mkdtempSync(join(tmpdir(), "web-next-queue-route-"));
process.env.SESSIONS_DATABASE_URL = `file:${join(dir, "test.db")}`;

afterAll(() => {
	rmSync(dir, { recursive: true, force: true });
});

const AUTHORIZED = {
	kind: "authorized" as const,
	user: { login: "fairchild", name: "Fairchild" },
};

beforeEach(() => {
	vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
});

let seq = 0;
async function freshSession(): Promise<string> {
	const id = `queue-${++seq}`;
	await createSession(getDatabase(), { id, ownerLogin: "fairchild", provider: "mock" });
	return id;
}

async function del(id: string, queueId: string) {
	const { DELETE } = await import("./route");
	return DELETE(
		new Request(`http://test/api/sessions/${id}/queue/${queueId}`, {
			method: "DELETE",
		}),
		{ params: Promise.resolve({ id, queueId }) },
	);
}

describe("DELETE /api/sessions/[id]/queue/[queueId]", () => {
	test("cancels an undispatched queued message", async () => {
		const id = await freshSession();
		const queued = await enqueueMessage(getDatabase(), id, "not anymore");

		const res = await del(id, queued.queueId);

		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ canceled: true, queueId: queued.queueId });
		expect(await listQueuedMessages(getDatabase(), id)).toEqual([]);
	});

	test("returns 409 once the queued message has dispatched", async () => {
		const id = await freshSession();
		const queued = await enqueueMessage(getDatabase(), id, "too late");
		await claimNextQueuedMessage(getDatabase(), id);

		const res = await del(id, queued.queueId);

		expect(res.status).toBe(409);
		expect((await res.json()).error).toMatch(/already dispatched/);
	});

	test("returns 404 for an unknown queue id", async () => {
		const id = await freshSession();
		const res = await del(id, "missing");
		expect(res.status).toBe(404);
	});
});
