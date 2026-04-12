import { getDb } from "./db";

let migrated = false;

async function ensureTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
	await db.schema
		.createTable("base_snapshots")
		.ifNotExists()
		.addColumn("provider", "text", (c) => c.notNull())
		.addColumn("version", "text", (c) => c.notNull())
		.addColumn("snapshot_id", "text", (c) => c.notNull())
		.addColumn("created_at", "text", (c) => c.notNull())
		.addPrimaryKeyConstraint("base_snapshots_pk", ["provider", "version"])
		.execute();
	migrated = true;
}

/** Look up the snapshot ID for a given provider + version. */
export async function getBaseSnapshotId(
	provider: string,
	version: string,
): Promise<string | null> {
	await ensureTable();
	const db = getDb();
	const row = await db
		.selectFrom("base_snapshots")
		.select("snapshot_id")
		.where("provider", "=", provider)
		.where("version", "=", version)
		.executeTakeFirst();
	return row?.snapshot_id ?? null;
}

/** Record a freshly created base snapshot. */
export async function recordBaseSnapshot(
	provider: string,
	version: string,
	snapshotId: string,
): Promise<void> {
	await ensureTable();
	const db = getDb();
	await db
		.insertInto("base_snapshots")
		.values({
			provider,
			version,
			snapshot_id: snapshotId,
			created_at: new Date().toISOString(),
		})
		.onConflict((oc) =>
			oc.columns(["provider", "version"]).doUpdateSet({
				snapshot_id: snapshotId,
				created_at: new Date().toISOString(),
			}),
		)
		.execute();
}
