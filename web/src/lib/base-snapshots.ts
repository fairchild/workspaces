/**
 * Persistence for `base_snapshots` — the provider base-image snapshot id for each
 * (provider, version), so a new sandbox restores a prepared base instead of
 * rebuilding it.
 */

import { getDb } from "./db";
import { ensureSchema } from "./schema";

/** Look up the snapshot ID for a given provider + version. */
export async function getBaseSnapshotId(
	provider: string,
	version: string,
): Promise<string | null> {
	await ensureSchema();
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
	await ensureSchema();
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
