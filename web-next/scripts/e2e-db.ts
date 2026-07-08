/*
 * Prepares the local Playwright database before workers start. The e2e server
 * runs this after cleaning `.data/` and before `next start`, so the first
 * browser worker never has to race sqlite file creation or schema migration.
 */
import { openDatabase } from "../src/lib/db/client";
import { ensureSchema } from "../src/lib/db/schema";

async function main() {
	const url = process.env.SESSIONS_DATABASE_URL ?? "file:.data/e2e.db";
	const handle = openDatabase(url);
	try {
		await handle.client.execute("PRAGMA journal_mode = WAL");
		await ensureSchema(handle);
		const applied = await handle.client.execute(
			"SELECT COUNT(*) AS count FROM schema_migrations",
		);
		console.log(
			`[e2e-db] ready ${url} (${String(applied.rows[0]?.count ?? 0)} migrations)`,
		);
	} finally {
		await handle.db.destroy();
		handle.client.close();
	}
}

main().catch((err) => {
	console.error("[e2e-db] fatal:", err);
	process.exit(1);
});
