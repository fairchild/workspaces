/*
 * The schema runner: applies ./migrations to a database handle and records
 * which have run in `schema_migrations`. Every store method awaits
 * `ensureSchema(handle)` before its first query. Idempotent and cheap after the
 * first call per handle — a per-handle promise cache dedupes concurrent
 * bootstraps and is cleared on failure so a later call retries.
 */
import type { DatabaseHandle } from "./client";
import { MIGRATIONS } from "./migrations";

/** One in-flight bootstrap per handle, so concurrent callers await one run. */
const ready = new WeakMap<object, Promise<void>>();

export function ensureSchema(handle: DatabaseHandle): Promise<void> {
	const existing = ready.get(handle.client);
	if (existing) return existing;
	const run = runMigrations(handle).catch((err) => {
		ready.delete(handle.client);
		throw err;
	});
	ready.set(handle.client, run);
	return run;
}

async function runMigrations({ client, db }: DatabaseHandle): Promise<void> {
	await client.execute(
		"CREATE TABLE IF NOT EXISTS schema_migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL)",
	);
	const appliedRows = await client.execute("SELECT id FROM schema_migrations");
	const applied = new Set(appliedRows.rows.map((r) => String(r.id)));

	for (const migration of MIGRATIONS) {
		if (applied.has(migration.id)) continue;
		await migration.up(db);
		await client.execute({
			sql: "INSERT OR IGNORE INTO schema_migrations (id, applied_at) VALUES (?, ?)",
			args: [migration.id, new Date().toISOString()],
		});
	}
}
