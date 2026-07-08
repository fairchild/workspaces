/*
 * /api/sessions/[id]/sandbox — the state poller is also the adaptive idle
 * sweeper, so these tests keep the sweep tied to the durable session_events
 * log instead of any process-local active-turn registry.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Sandbox } from "@vercel/sandbox";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { ADAPTIVE_IDLE_STOP_MS } from "@/lib/agent-runtime/sandbox-state";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import {
	appendEvents,
	createSession,
	updateSession,
	type AppendEvent,
} from "@/lib/db/sessions";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

vi.mock("@vercel/sandbox", () => ({
	Sandbox: { get: vi.fn() },
}));

const dir = mkdtempSync(join(tmpdir(), "web-next-sandbox-route-"));
process.env.SESSIONS_DATABASE_URL = `file:${join(dir, "test.db")}`;

afterAll(() => {
	rmSync(dir, { recursive: true, force: true });
});

const AUTHORIZED = {
	kind: "authorized" as const,
	user: { login: "fairchild", name: "Fairchild" },
};

const NOW = new Date("2026-07-08T17:00:00.000Z");

beforeEach(() => {
	vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
	vi.mocked(Sandbox.get).mockReset();
});

let seq = 0;

async function get(id: string) {
	const { GET } = await import("./route");
	return GET(new Request(`http://test/api/sessions/${id}/sandbox`), {
		params: Promise.resolve({ id }),
	});
}

async function sessionPastIdleWindow(events: readonly AppendEvent[]): Promise<string> {
	const id = `sandbox-s-${++seq}`;
	await createSession(getDatabase(), {
		id,
		provider: "vercel",
		ownerLogin: "fairchild",
	});
	await updateSession(getDatabase(), id, {
		claudeSessionId: "harness-1",
		resumeState: '{"parked":true}',
	});
	await appendEvents(getDatabase(), id, events);
	await getDatabase()
		.db.updateTable("sessions")
		.set({
			last_activity_at: new Date(
				NOW.getTime() - ADAPTIVE_IDLE_STOP_MS - 1_000,
			).toISOString(),
		})
		.where("id", "=", id)
		.execute();
	return id;
}

function liveSandbox() {
	return {
		name: "wm-harness-1",
		status: "running",
		stop: vi.fn(async () => ({})),
	};
}

describe("GET /api/sessions/[id]/sandbox", () => {
	test("does not idle-stop a live sandbox while the current turn is unsettled in the durable log", async () => {
		const sandbox = liveSandbox();
		vi.mocked(Sandbox.get).mockResolvedValue(sandbox as never);
		const id = await sessionPastIdleWindow([
			{ role: "user", chunk: { type: "text", content: "run the long build" } },
			{ role: "assistant", chunk: { type: "tool_use", content: "pnpm build" } },
		]);

		const res = await get(id);

		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ state: "live" });
		expect(sandbox.stop).not.toHaveBeenCalled();
	});

	test("idle-stops a live sandbox past the window after the current turn settled", async () => {
		const sandbox = liveSandbox();
		vi.mocked(Sandbox.get).mockResolvedValue(sandbox as never);
		const id = await sessionPastIdleWindow([
			{ role: "user", chunk: { type: "text", content: "run the build" } },
			{ role: "assistant", chunk: { type: "done", content: "" } },
		]);

		const res = await get(id);

		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ state: "parked", detail: "stopped" });
		expect(sandbox.stop).toHaveBeenCalledTimes(1);
	});
});
