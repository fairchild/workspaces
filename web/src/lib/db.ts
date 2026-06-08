import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { type Client, createClient } from "@libsql/client";
import { Kysely } from "kysely";
import { LibsqlDialect } from "./libsql-dialect";

export interface EventsTable {
	id: string;
	type: string;
	action: string;
	summary: string;
	repo: string;
	timestamp: string;
	payload: string;
}

export interface ChatMessagesTable {
	id: string;
	repo: string;
	author: string;
	author_type: string;
	content: string;
	agent_target: string | null;
	discussion_id: string | null;
	discussion_url: string | null;
	timestamp: string;
}

export interface WorkspacesTable {
	owner_id: string | null;
	id: string;
	name: string;
	path: string;
	repo_id: string | null;
	repo_name: string | null;
	created_at: string;
	last_accessed_at: string;
	status: string;
	git_branch: string | null;
	backend_identifier: string;
	synced_at: string;
}

export interface AgentSessionsTable {
	id: string;
	user_id: string | null;
	repo: string;
	agent_name: string;
	compute_backend: string;
	compute_instance_id: string | null;
	snapshot_id: string | null;
	claude_session_id: string | null;
	thread_id: string;
	discussion_id: string | null;
	status: string;
	created_at: string;
	last_activity_at: string;
}

export interface BaseSnapshotsTable {
	provider: string;
	version: string;
	snapshot_id: string;
	created_at: string;
}

export interface ManagedAgentsCacheTable {
	kind: string;
	hash: string;
	remote_id: string;
	created_at: string;
	metadata: string | null;
}

export interface ManagedPrReviewRunsTable {
	fingerprint: string;
	repo_full_name: string;
	pr_number: number;
	head_sha: string;
	trigger_kind: string;
	trigger_source_id: string;
	reviewer_config_hash: string;
	session_id: string | null;
	status: string;
	created_at: string;
	updated_at: string;
	error: string | null;
	failure_kind: string | null;
	failure_message: string | null;
	failure_retryable: number | null;
	failed_at: string | null;
	projection_status: string | null;
	projection_updated_at: string | null;
	projection_error: string | null;
	github_review_id: string | null;
	review_intent_event: string | null;
	review_intent_body: string | null;
	review_intent_labels: string | null;
	review_intent_recorded_at: string | null;
	active_claim_key: string | null;
	coalesced_head_sha: string | null;
	coalesced_trigger_kind: string | null;
	coalesced_trigger_source_id: string | null;
	coalesced_at: string | null;
}

export interface ManagedPrReviewProjectionsTable {
	projection_id: string;
	run_fingerprint: string;
	projection_type: string;
	projection_key: string;
	desired_payload_hash: string;
	desired_payload: string;
	state: string;
	attempts: number;
	last_attempted_at: string | null;
	observed_external_id: string | null;
	error_kind: string | null;
	error_text: string | null;
	created_at: string;
	updated_at: string;
}

export interface Database {
	webhook_events: EventsTable;
	chat_messages: ChatMessagesTable;
	workspaces: WorkspacesTable;
	agent_sessions: AgentSessionsTable;
	base_snapshots: BaseSnapshotsTable;
	managed_agents_cache: ManagedAgentsCacheTable;
	managed_pr_review_runs: ManagedPrReviewRunsTable;
	managed_pr_review_projections: ManagedPrReviewProjectionsTable;
}

let _turso: Client | undefined;
let _dialect: LibsqlDialect | undefined;
let _db: Kysely<Database> | undefined;

export function getTurso(): Client {
	if (!_turso) {
		const url = process.env.TURSO_DATABASE_URL ?? "file:data/auth.db";
		if (url.startsWith("file:")) {
			mkdirSync(dirname(url.slice(5)), { recursive: true });
		}
		_turso = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
	}
	return _turso;
}

export function getDialect(): LibsqlDialect {
	if (!_dialect) {
		_dialect = new LibsqlDialect({ client: getTurso() });
	}
	return _dialect;
}

export function getDb(): Kysely<Database> {
	if (!_db) {
		_db = new Kysely<Database>({ dialect: getDialect() });
	}
	return _db;
}
