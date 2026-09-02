/*
 * Shared harness for the evidence and perf scripts: serve the production
 * build on a port — in auth-bypass mode over a throwaway database — and
 * launch Chromium (honoring the remote-sandbox executable override).
 * Node-only, no test framework.
 */
import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

export const WEB_NEXT_ROOT = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);

/** The login the harness servers allowlist and their browsers act as. */
export const HARNESS_LOGIN = "fairchild";

/** Mirrors TEST_AUTH_COOKIE in src/lib/auth/config.ts. */
const TEST_AUTH_COOKIE = "test-auth-login";

/** Playwright cookie that signs a context in under the auth bypass. */
export function testAuthCookie(baseUrl, login = HARNESS_LOGIN) {
	return { name: TEST_AUTH_COOKIE, value: login, url: baseUrl };
}

/** The tables the evidence and perf runs seed and wipe directly. */
export const SEEDED_TABLES = ["repos", "sessions", "session_events"];

const sleepMs = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function missingSeedTables(db, required) {
	const { rows } = await db.execute(
		"SELECT name FROM sqlite_master WHERE type = 'table'",
	);
	const present = new Set(rows.map((row) => row.name));
	return required.filter((table) => !present.has(table));
}

/**
 * Proves the warm-up actually migrated the schema instead of trusting its
 * status code. A warm-up that follows a redirect to /sign-in answers 200
 * having never opened the sessions database, and the first `DELETE FROM
 * session_events` is where that used to surface — as `no such table`, three
 * steps from its cause (#976). Migration can land just after the response, so
 * poll briefly before giving up.
 */
export async function assertSeedSchemaReady(
	db,
	{
		landedUrl,
		requiredTables = SEEDED_TABLES,
		attempts = 20,
		intervalMs = 250,
		sleep = sleepMs,
	} = {},
) {
	let missing = requiredTables;
	for (let attempt = 0; attempt < attempts; attempt += 1) {
		missing = await missingSeedTables(db, requiredTables);
		if (missing.length === 0) return;
		if (attempt < attempts - 1) await sleep(intervalMs);
	}
	throw new Error(
		`Schema warm-up answered 200 from ${landedUrl} but the sessions schema is not migrated — missing table(s): ${missing.join(", ")}. ` +
			"The warm-up has to land on an authed, DB-touching page; a redirect to /sign-in answers 200 without ever opening the sessions database. " +
			`Check AUTH_BYPASS, ALLOWED_LOGINS, and the ${TEST_AUTH_COOKIE} cookie for ${HARNESS_LOGIN}.`,
	);
}

/**
 * Connects to the harness server's database for direct seeding/wiping.
 * Loads the home page once (signed in) so the app runs its migrations, then
 * verifies the tables exist before handing the client back.
 */
export async function connectSeedClient(
	baseUrl,
	databaseUrl,
	{ fetchImpl = fetch, createClient, ...schemaOptions } = {},
) {
	const response = await fetchImpl(baseUrl, {
		headers: { cookie: `${TEST_AUTH_COOKIE}=${HARNESS_LOGIN}` },
	});
	if (!response.ok) {
		throw new Error(
			`schema warm-up failed: HTTP ${response.status} from ${response.url ?? baseUrl}`,
		);
	}
	const create =
		createClient ?? (await import("@libsql/client")).createClient;
	const db = create({ url: databaseUrl });
	try {
		await assertSeedSchemaReady(db, {
			landedUrl: response.url ?? baseUrl,
			...schemaOptions,
		});
	} catch (error) {
		db.close();
		throw error;
	}
	return db;
}

/**
 * Auth-bypass server env over a fresh database file (recreated per run) —
 * what evidence/perf runs pass to startProductionServer. Returns the env
 * plus the db url so callers can seed/wipe rows directly.
 */
export function bypassServerEnv(dbDirName) {
	const dbDir = path.join(WEB_NEXT_ROOT, "output", dbDirName);
	rmSync(dbDir, { recursive: true, force: true });
	mkdirSync(dbDir, { recursive: true });
	const databaseUrl = `file:${path.join(dbDir, "sessions.db")}`;
	return {
		env: {
			AUTH_BYPASS: "1",
			ALLOWED_LOGINS: HARNESS_LOGIN,
			SESSIONS_DATABASE_URL: databaseUrl,
		},
		databaseUrl,
	};
}

/**
 * Local-mode server env over a fresh WEB_NEXT_DATA_DIR. The token is persisted
 * where the app expects it and exported for middleware, matching start:local.
 */
export function localModeServerEnv(dbDirName) {
	const dataDir = path.join(WEB_NEXT_ROOT, "output", dbDirName);
	rmSync(dataDir, { recursive: true, force: true });
	mkdirSync(dataDir, { recursive: true });
	const token = randomBytes(32).toString("base64url");
	writeFileSync(path.join(dataDir, "local-sign-in-token"), `${token}\n`, {
		mode: 0o600,
	});
	return {
		env: {
			WEB_NEXT_LOCAL_MODE: "1",
			WEB_NEXT_LOCAL_TOKEN: token,
			WEB_NEXT_DATA_DIR: dataDir,
			WEB_NEXT_LOCAL_LOGIN: HARNESS_LOGIN,
			AUTH_BYPASS: "",
			GITHUB_OAUTH_CLIENT_ID: "",
			GITHUB_OAUTH_CLIENT_SECRET: "",
		},
		token,
		dataDir,
	};
}

/** Fails fast when `next build` hasn't produced a servable build. */
export function assertProductionBuild() {
	if (!existsSync(path.join(WEB_NEXT_ROOT, ".next", "BUILD_ID"))) {
		throw new Error("No production build found — run `pnpm build` first.");
	}
}

async function waitForServer(url, timeoutMs = 60_000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			const res = await fetch(url);
			if (res.ok) return;
		} catch {
			// Server not accepting connections yet.
		}
		await new Promise((r) => setTimeout(r, 250));
	}
	throw new Error(`Server at ${url} not ready within ${timeoutMs}ms`);
}

function hostHasListener(port, host) {
	return new Promise((resolve) => {
		const socket = connect({ port, host });
		let settled = false;
		const finish = (value) => {
			if (settled) return;
			settled = true;
			socket.destroy();
			resolve(value);
		};
		socket.setTimeout(500, () => finish(false));
		socket.once("connect", () => finish(true));
		// Any connection error means this address did not accept a connection.
		// In particular, IPv6-less runners may report EADDRNOTAVAIL for ::1.
		socket.once("error", () => finish(false));
	});
}

async function loopbackHasListener(port) {
	const results = await Promise.all([
		hostHasListener(port, "127.0.0.1"),
		hostHasListener(port, "::1"),
	]);
	return results.some(Boolean);
}

function describePortOwner(port) {
	try {
		const output = execFileSync(
			"lsof",
			["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-Fpc"],
			{ encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
		);
		let pid;
		let command;
		for (const line of output.split("\n")) {
			if (!pid && line.startsWith("p")) pid = line.slice(1);
			if (!command && line.startsWith("c")) command = line.slice(1);
			if (pid && command) break;
		}
		if (!pid && !command) return "";
		return ` (${[pid && `PID ${pid}`, command].filter(Boolean).join(", ")})`;
	} catch {
		return "";
	}
}

/** Refuse to let a stale server satisfy readiness for a newly spawned child. */
export async function assertPortAvailable(
	port,
	{ probe = loopbackHasListener, describeOwner = describePortOwner } = {},
) {
	if (await probe(port)) {
		throw new Error(
			`Harness port ${port} is already listening${describeOwner(port)}; stop that process or choose another EVIDENCE_PORT/PERF_PORT.`,
		);
	}
}

function terminateChildProcessGroup(child, signal = "SIGTERM") {
	if (!child || child.exitCode != null || child.signalCode != null) return;
	try {
		process.kill(-child.pid, signal);
	} catch {
		try {
			child.kill(signal);
		} catch {
			// Best effort during process teardown: the child may already be gone.
		}
	}
}

/** Keep detached `next start` descendants tied to the harness parent lifetime. */
export function registerParentExitCleanup(
	child,
	{
		parent = process,
		terminate = terminateChildProcessGroup,
		resignal = (signal) => process.kill(process.pid, signal),
	} = {},
) {
	let registered = true;
	const onExit = () => terminate(child, "SIGTERM");
	const signalHandlers = new Map(
		["SIGINT", "SIGTERM"].map((signal) => [
			signal,
			() => {
				unregister();
				terminate(child, "SIGTERM");
				resignal(signal);
			},
		]),
	);
	parent.once("exit", onExit);
	for (const [signal, handler] of signalHandlers) parent.once(signal, handler);
	function unregister() {
		if (!registered) return;
		registered = false;
		parent.off("exit", onExit);
		for (const [signal, handler] of signalHandlers) parent.off(signal, handler);
	}
	return unregister;
}

/** Close every acquired harness resource even when an earlier close fails. */
export async function closeHarnessResources({ browser, database, server }) {
	const errors = [];
	try {
		await browser?.close();
	} catch (error) {
		errors.push(error);
	}
	try {
		database?.close();
	} catch (error) {
		errors.push(error);
	}
	try {
		await server?.stop();
	} catch (error) {
		errors.push(error);
	}
	if (errors.length > 0) {
		throw new AggregateError(errors, "Failed to close every harness resource");
	}
}

/**
 * Starts `next start` on the given port (with optional extra env) and
 * resolves once it serves 200s. Returns { baseUrl, stop } — always call
 * stop() when done.
 */
export async function startProductionServer(port = 3100, env = {}) {
	assertProductionBuild();
	await assertPortAvailable(port);
	const args =
		env.WEB_NEXT_LOCAL_MODE === "1"
			? ["exec", "next", "start", "-H", "127.0.0.1", "--port", String(port)]
			: ["exec", "next", "start", "--port", String(port)];
	const child = spawn(
		"pnpm",
		args,
		{
			cwd: WEB_NEXT_ROOT,
			stdio: ["ignore", "pipe", "pipe"],
			env: { ...process.env, ...env },
			detached: true,
		},
	);
	const unregisterExitCleanup = registerParentExitCleanup(child);
	const baseUrl = `http://localhost:${port}`;
	try {
		await waitForServer(baseUrl);
	} catch (error) {
		unregisterExitCleanup();
		terminateChildProcessGroup(child, "SIGTERM");
		throw error;
	}
	let stopPromise;
	return {
		baseUrl,
		stop: () => {
			if (stopPromise) return stopPromise;
			stopPromise = new Promise((resolve) => {
				unregisterExitCleanup();
				let done = false;
				const finish = () => {
					if (done) return;
					done = true;
					resolve();
				};
				const killTimer = setTimeout(() => {
					terminateChildProcessGroup(child, "SIGKILL");
					finish();
				}, 5_000);
				killTimer.unref();
				child.once("exit", () => {
					clearTimeout(killTimer);
					finish();
				});
				if (child.exitCode != null || child.signalCode != null) {
					clearTimeout(killTimer);
					finish();
					return;
				}
				terminateChildProcessGroup(child, "SIGTERM");
			});
			return stopPromise;
		},
	};
}

/**
 * Launches headless Chromium, using PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH when
 * set (remote sandboxes preinstall a browser and block Playwright's CDN — see
 * docs/development/remote-sessions.md).
 */
export function launchChromium() {
	const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
	return chromium.launch(executablePath ? { executablePath } : {});
}
