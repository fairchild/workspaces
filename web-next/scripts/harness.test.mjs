import { EventEmitter } from "node:events";
import { createServer } from "node:net";
import { describe, expect, test, vi } from "vitest";
import {
	assertPortAvailable,
	closeHarnessResources,
	connectSeedClient,
	registerParentExitCleanup,
	SEEDED_TABLES,
} from "./harness.mjs";

describe("seed-client schema warm-up", () => {
	const okResponse = (url = "http://localhost:3100/") => ({
		ok: true,
		status: 200,
		url,
	});

	/**
	 * A libsql-shaped client whose sqlite_master answers each given table set
	 * in turn, repeating the last one — one set per expected probe.
	 */
	const dbWithTables = (...tableSets) => {
		let probe = 0;
		return {
			execute: vi.fn(async () => {
				const tables = tableSets[Math.min(probe++, tableSets.length - 1)];
				return { rows: tables.map((name) => ({ name })) };
			}),
			close: vi.fn(),
		};
	};

	const connect = (db, options = {}) =>
		connectSeedClient("http://localhost:3100", "file:/tmp/x.db", {
			fetchImpl: vi.fn().mockResolvedValue(okResponse(options.landedUrl)),
			createClient: () => db,
			sleep: vi.fn().mockResolvedValue(undefined),
			attempts: 3,
			...options,
		});

	test("hands back a client once every seeded table exists", async () => {
		const db = dbWithTables(SEEDED_TABLES);

		await expect(connect(db)).resolves.toBe(db);
		expect(db.close).not.toHaveBeenCalled();
	});

	test("a 200 that never migrated the schema fails at the warm-up, not the first DELETE", async () => {
		const db = dbWithTables([]);

		await expect(
			connect(db, { landedUrl: "http://localhost:3100/sign-in" }),
		).rejects.toThrow(/schema is not migrated/i);
	});

	test("the failure names where the warm-up landed and what is missing", async () => {
		const db = dbWithTables(["repos"]);

		await expect(
			connect(db, { landedUrl: "http://localhost:3100/sign-in" }),
		).rejects.toThrow(/sign-in.*sessions, session_events/s);
	});

	test("closes the client it opened rather than leaking it on failure", async () => {
		const db = dbWithTables([]);

		await expect(connect(db)).rejects.toThrow();
		expect(db.close).toHaveBeenCalledOnce();
	});

	test("tolerates a migration that lands just after the warm-up response", async () => {
		const db = dbWithTables([], SEEDED_TABLES);
		const sleep = vi.fn().mockResolvedValue(undefined);

		await expect(connect(db, { sleep })).resolves.toBe(db);
		expect(sleep).toHaveBeenCalledOnce();
	});

	test("a non-200 warm-up still fails before any client is opened", async () => {
		const createClient = vi.fn();

		await expect(
			connectSeedClient("http://localhost:3100", "file:/tmp/x.db", {
				fetchImpl: vi
					.fn()
					.mockResolvedValue({ ok: false, status: 503, url: "http://localhost:3100/" }),
				createClient,
			}),
		).rejects.toThrow(/HTTP 503/);
		expect(createClient).not.toHaveBeenCalled();
	});
});

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

	test("detects a real IPv4 loopback listener", async () => {
		const listener = createServer();
		await new Promise((resolve, reject) => {
			listener.once("error", reject);
			listener.listen(0, "127.0.0.1", resolve);
		});
		try {
			const address = listener.address();
			expect(address).not.toBeNull();
			await expect(
				assertPortAvailable(address.port, { describeOwner: () => "" }),
			).rejects.toThrow(/already listening/i);
		} finally {
			await new Promise((resolve, reject) =>
				listener.close((error) => (error ? reject(error) : resolve())),
			);
		}
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
