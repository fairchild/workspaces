import { getDb, getTurso } from "../db";
import { MIGRATIONS } from "./migrations";

/**
 * Single in-flight bootstrap promise so concurrent callers (one warm serverless
 * instance serves many requests) await one run rather than racing — a plain boolean
 * would flip before its async body finished. Cleared on failure so a later call retries.
 */
let schemaReady: Promise<void> | undefined;

/**
 * Ensure every table the app reads/writes exists and is current. Every persistence
 * query awaits this before its first database access. Idempotent and cheap after the
 * first call — subsequent calls await the already-resolved promise.
 */
export function ensureSchema(): Promise<void> {
	if (!schemaReady) {
		schemaReady = runMigrations().catch((err) => {
			schemaReady = undefined;
			throw err;
		});
	}
	return schemaReady;
}

async function runMigrations(): Promise<void> {
	const turso = getTurso();
	await turso.execute(
		"CREATE TABLE IF NOT EXISTS schema_migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL)",
	);
	const appliedRows = await turso.execute("SELECT id FROM schema_migrations");
	const applied = new Set(appliedRows.rows.map((r) => String(r.id)));

	const db = getDb();
	for (const migration of MIGRATIONS) {
		if (applied.has(migration.id)) continue;
		await migration.up(db);
		await turso.execute({
			sql: "INSERT INTO schema_migrations (id, applied_at) VALUES (?, ?)",
			args: [migration.id, new Date().toISOString()],
		});
	}
}

/**
 * Test-only: forget the cached bootstrap so the next `ensureSchema()` re-runs
 * against a fresh in-memory database.
 */
export function resetSchemaForTests(): void {
	schemaReady = undefined;
}
