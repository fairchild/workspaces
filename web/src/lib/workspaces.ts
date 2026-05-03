import { getDb } from "./db";
import { formatRelativeTime } from "./timeline-utils";
import type { Workspace, WorkspaceStatus } from "./types";

export const DEFAULT_WORKSPACE_OWNER_ID = "default";

let migrated = false;

async function ensureWorkspacesTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
	await db.schema
		.createTable("workspaces")
		.ifNotExists()
		.addColumn("owner_id", "text", (c) =>
			c.notNull().defaultTo(DEFAULT_WORKSPACE_OWNER_ID),
		)
		.addColumn("id", "text", (c) => c.primaryKey())
		.addColumn("name", "text", (c) => c.notNull())
		.addColumn("path", "text", (c) => c.notNull())
		.addColumn("repo_id", "text")
		.addColumn("repo_name", "text")
		.addColumn("created_at", "text", (c) => c.notNull())
		.addColumn("last_accessed_at", "text", (c) => c.notNull())
		.addColumn("status", "text", (c) => c.notNull().defaultTo("stopped"))
		.addColumn("git_branch", "text")
		.addColumn("backend_identifier", "text", (c) =>
			c.notNull().defaultTo("local"),
		)
		.addColumn("synced_at", "text", (c) => c.notNull())
		.execute();
	try {
		await db.schema
			.alterTable("workspaces")
			.addColumn("owner_id", "text")
			.execute();
	} catch {
		// Column already exists.
	}
	await db
		.updateTable("workspaces")
		.set({ owner_id: DEFAULT_WORKSPACE_OWNER_ID })
		.where("owner_id", "is", null)
		.execute();
	await db.schema
		.createIndex("idx_workspaces_owner")
		.ifNotExists()
		.on("workspaces")
		.column("owner_id")
		.execute();
	migrated = true;
}

export interface SyncWorkspaceInput {
	id: string;
	name: string;
	path: string;
	repoId?: string | null;
	repoName?: string | null;
	createdAt: string;
	lastAccessedAt: string;
	status: WorkspaceStatus;
	gitBranch?: string | null;
	backendIdentifier: string;
}

export async function syncWorkspaces(
	ownerId: string,
	workspaces: SyncWorkspaceInput[],
): Promise<number> {
	await ensureWorkspacesTable();
	const db = getDb();
	const now = new Date().toISOString();

	await Promise.all(
		workspaces.map((ws) =>
			db
				.insertInto("workspaces")
				.values({
					owner_id: ownerId,
					id: ws.id,
					name: ws.name,
					path: ws.path,
					repo_id: ws.repoId ?? null,
					repo_name: ws.repoName ?? null,
					created_at: ws.createdAt,
					last_accessed_at: ws.lastAccessedAt,
					status: ws.status,
					git_branch: ws.gitBranch ?? null,
					backend_identifier: ws.backendIdentifier,
					synced_at: now,
				})
				.onConflict((oc) =>
					oc.column("id").doUpdateSet({
						owner_id: ownerId,
						name: ws.name,
						path: ws.path,
						repo_id: ws.repoId ?? null,
						repo_name: ws.repoName ?? null,
						last_accessed_at: ws.lastAccessedAt,
						status: ws.status,
						git_branch: ws.gitBranch ?? null,
						backend_identifier: ws.backendIdentifier,
						synced_at: now,
					}),
				)
				.execute(),
		),
	);

	return workspaces.length;
}

export async function getWorkspaces(
	ownerId: string,
	repo?: string | null,
): Promise<Workspace[]> {
	await ensureWorkspacesTable();
	const db = getDb();
	let query = db
		.selectFrom("workspaces")
		.selectAll()
		.where("owner_id", "=", ownerId)
		.orderBy("last_accessed_at", "desc");
	if (repo) {
		query = query.where("repo_name", "=", repo);
	}
	const rows = await query.execute();
	return rows.map((r) => ({
		id: r.id,
		name: r.name,
		path: r.path,
		repoId: r.repo_id,
		repoName: r.repo_name,
		createdAt: r.created_at,
		lastAccessedAt: r.last_accessed_at,
		status: r.status as WorkspaceStatus,
		gitBranch: r.git_branch,
		backendIdentifier: r.backend_identifier,
	}));
}

const STATUS_EMOJI: Record<WorkspaceStatus, string> = {
	active: "🟢",
	provisioning: "🟡",
	stopped: "🔴",
	archived: "⚪",
};

export function formatWorkspaceStatusCard(workspaces: Workspace[]): string {
	if (workspaces.length === 0) {
		return "No workspaces tracked yet.";
	}

	const header =
		"| Workspace | Status | Branch | Last Activity |\n| --- | --- | --- | --- |";
	const rows = workspaces.map((ws) => {
		const emoji = STATUS_EMOJI[ws.status] ?? "⚪";
		const branch = ws.gitBranch ?? "—";
		const activity = formatRelativeTime(ws.lastAccessedAt);
		return `| ${ws.name} | ${emoji} ${ws.status} | \`${branch}\` | ${activity} |`;
	});

	return `**Workspace Status**\n\n${header}\n${rows.join("\n")}`;
}
