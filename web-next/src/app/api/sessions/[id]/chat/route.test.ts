/*
 * POST /api/sessions/[id]/chat — route response semantics around turn start
 * vs durable queueing. The runtime/store tests cover the queue's persistence
 * and dispatch behavior; this file keeps the HTTP contract focused.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { getAuthState } from "@/lib/auth/auth-state";
import { queueSessionTurn, runSessionTurn } from "@/lib/agent-runtime/run-turn";
import { getDatabase } from "@/lib/db/client";
import { createSession } from "@/lib/db/sessions";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

vi.mock("@/lib/agent-runtime/run-turn", () => ({
	runSessionTurn: vi.fn(),
	queueSessionTurn: vi.fn(),
}));

const dir = mkdtempSync(join(tmpdir(), "web-next-chat-route-"));
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
	vi.mocked(runSessionTurn).mockReset();
	vi.mocked(queueSessionTurn).mockReset();
});

let seq = 0;
async function freshSession(): Promise<string> {
	const id = `chat-${++seq}`;
	await createSession(getDatabase(), { id, ownerLogin: "fairchild", provider: "mock" });
	return id;
}

async function post(id: string, body: unknown) {
	const { POST } = await import("./route");
	return POST(
		new Request(`http://test/api/sessions/${id}/chat`, {
			method: "POST",
			body: JSON.stringify(body),
		}),
		{ params: Promise.resolve({ id }) },
	);
}

describe("POST /api/sessions/[id]/chat", () => {
	test("returns 202 JSON when the turn starter queues a mid-turn send", async () => {
		const id = await freshSession();
		vi.mocked(runSessionTurn).mockResolvedValue({
			kind: "queued",
			queueId: "q-1",
			position: 1,
			queuedAt: "2026-01-01T00:00:00.000Z",
		});

		const res = await post(id, {
			text: "steer next",
			requestId: "request-1",
			retryOf: "message-0",
		});

		expect(res.status).toBe(202);
		expect(await res.json()).toEqual({
			queued: true,
			queueId: "q-1",
			position: 1,
		});
		expect(runSessionTurn).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ id }),
			"steer next",
		);
	});

	test("queue=true forces the durable queue path for busy clients", async () => {
		const id = await freshSession();
		vi.mocked(queueSessionTurn).mockResolvedValue({
			kind: "queued",
			queueId: "q-forced",
			position: 2,
			queuedAt: "2026-01-01T00:00:00.000Z",
		});

		const res = await post(id, {
			text: "still next",
			requestId: "request-2",
			retryOf: "message-1",
			queue: true,
		});

		expect(res.status).toBe(202);
		expect(await res.json()).toMatchObject({
			queued: true,
			queueId: "q-forced",
			position: 2,
		});
		expect(queueSessionTurn).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ id }),
			"still next",
		);
		expect(runSessionTurn).not.toHaveBeenCalled();
	});
});
