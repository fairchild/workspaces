/*
 * Persistence for connected repositories. Deliberately thin for the
 * single-user product: repos are keyed by `owner/name` (the id IS the
 * full name until a GitHub sync gives us node ids), created on first use
 * from the new-session flow, and listed for the repo picker.
 */
import type { DatabaseHandle, ReposTable } from "./client";
import { ensureSchema } from "./schema";

export interface Repo {
	id: string;
	fullName: string;
	defaultBranch: string | null;
	createdAt: string;
}

function rowToRepo(row: ReposTable): Repo {
	return {
		id: row.id,
		fullName: row.full_name,
		defaultBranch: row.default_branch,
		createdAt: row.created_at,
	};
}

/** Connected repos, alphabetical — the picker's order. */
export async function listRepos(handle: DatabaseHandle): Promise<Repo[]> {
	await ensureSchema(handle);
	const rows = await handle.db
		.selectFrom("repos")
		.selectAll()
		.orderBy("full_name", "asc")
		.execute();
	return rows.map(rowToRepo);
}

export async function getRepo(
	handle: DatabaseHandle,
	id: string,
): Promise<Repo | undefined> {
	await ensureSchema(handle);
	const row = await handle.db
		.selectFrom("repos")
		.selectAll()
		.where("id", "=", id)
		.executeTakeFirst();
	return row ? rowToRepo(row) : undefined;
}

/** The repo named `fullName`, created if this is its first mention. */
export async function ensureRepo(
	handle: DatabaseHandle,
	fullName: string,
): Promise<Repo> {
	await ensureSchema(handle);
	const existing = await handle.db
		.selectFrom("repos")
		.selectAll()
		.where("full_name", "=", fullName)
		.executeTakeFirst();
	if (existing) return rowToRepo(existing);

	const row: ReposTable = {
		id: fullName,
		full_name: fullName,
		default_branch: null,
		created_at: new Date().toISOString(),
	};
	await handle.db.insertInto("repos").values(row).execute();
	return rowToRepo(row);
}
