import { EventEmitter } from "node:events";
import { describe, expect, test, vi } from "vitest";
import {
	assertPortAvailable,
	closeHarnessResources,
	registerParentExitCleanup,
} from "./harness.mjs";

describe("production harness lifecycle", () => {
	test("refuses an occupied port before a stale server can satisfy readiness", async () => {
		const port = 3187;
		const probe = vi.fn().mockResolvedValue(true);

		await expect(
			assertPortAvailable(port, { probe, describeOwner: () => " (PID 123, node)" }),
		).rejects.toThrow(
			new RegExp(`port ${port}.*already`, "i"),
		);
		expect(probe).toHaveBeenCalledWith(port);
	});

	test("allows a port with no loopback listener", async () => {
		const probe = vi.fn().mockResolvedValue(false);

		await expect(assertPortAvailable(3188, { probe })).resolves.toBeUndefined();
	});

	test("terminates the child on parent exit and unregisters after normal cleanup", () => {
		const parent = new EventEmitter();
		const child = { pid: 42 };
		const terminate = vi.fn();
		const unregister = registerParentExitCleanup(child, { parent, terminate });

		parent.emit("exit");
		expect(terminate).toHaveBeenCalledOnce();
		expect(terminate).toHaveBeenCalledWith(child, "SIGTERM");

		unregister();
		parent.emit("exit");
		expect(terminate).toHaveBeenCalledOnce();
	});

	test("cleans up and re-raises termination signals after removing its handlers", () => {
		const parent = new EventEmitter();
		const child = { pid: 42 };
		const terminate = vi.fn();
		const resignal = vi.fn();
		registerParentExitCleanup(child, { parent, terminate, resignal });

		parent.emit("SIGTERM");

		expect(terminate).toHaveBeenCalledWith(child, "SIGTERM");
		expect(resignal).toHaveBeenCalledWith("SIGTERM");
		expect(parent.listenerCount("exit")).toBe(0);
		expect(parent.listenerCount("SIGINT")).toBe(0);
		expect(parent.listenerCount("SIGTERM")).toBe(0);
	});

	test("attempts every cleanup when an earlier resource close fails", async () => {
		const browser = {
			close: vi.fn().mockRejectedValue(new Error("browser close failed")),
		};
		const database = {
			close: vi.fn(() => {
				throw new Error("database close failed");
			}),
		};
		const server = { stop: vi.fn().mockResolvedValue(undefined) };

		await expect(
			closeHarnessResources({ browser, database, server }),
		).rejects.toThrow(AggregateError);
		expect(browser.close).toHaveBeenCalledOnce();
		expect(database.close).toHaveBeenCalledOnce();
		expect(server.stop).toHaveBeenCalledOnce();
	});
});
