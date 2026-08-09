import type { Env } from "./types";

export async function ensureSchema(env: Env): Promise<void> {
  await env.FEEDBACK_DB.exec(
    "CREATE TABLE IF NOT EXISTS feedback (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, kind TEXT NOT NULL, message TEXT NOT NULL, contact_email TEXT, submitter_login TEXT, submitter_id TEXT, app_version TEXT NOT NULL, os_version TEXT NOT NULL, client TEXT NOT NULL, ip_hash TEXT, status TEXT NOT NULL DEFAULT 'new', admin_notes TEXT, github_issue_url TEXT, attachment_prefix TEXT, has_screenshot INTEGER NOT NULL DEFAULT 0, has_diagnostics INTEGER NOT NULL DEFAULT 0);"
  );
  await env.FEEDBACK_DB.exec(
    "CREATE INDEX IF NOT EXISTS idx_feedback_created_at ON feedback(created_at);"
  );
  await env.FEEDBACK_DB.exec(
    "CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status);"
  );
  await env.FEEDBACK_DB.exec(
    "CREATE INDEX IF NOT EXISTS idx_feedback_kind ON feedback(kind);"
  );
  // Append-only trail of who published what — the admin UI writes here so a
  // publish always has an accountable actor (guards against silent duplicates).
  await env.FEEDBACK_DB.exec(
    "CREATE TABLE IF NOT EXISTS feedback_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, feedback_id TEXT NOT NULL, at INTEGER NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, detail TEXT);"
  );
  await env.FEEDBACK_DB.exec(
    "CREATE INDEX IF NOT EXISTS idx_feedback_audit_feedback_id ON feedback_audit(feedback_id);"
  );
}

/** Bound audit insert, for callers that batch it atomically with the mutation it records. */
export function auditStatement(
  env: Env,
  feedbackId: string,
  actor: string,
  action: string,
  detail?: string
): D1PreparedStatement {
  return env.FEEDBACK_DB.prepare(
    "INSERT INTO feedback_audit (feedback_id, at, actor, action, detail) VALUES (?, ?, ?, ?, ?)"
  ).bind(feedbackId, Date.now(), actor, action, detail ?? null);
}

/** Record an actor's action against a feedback row. Never throws on the caller's path. */
export async function recordAudit(
  env: Env,
  feedbackId: string,
  actor: string,
  action: string,
  detail?: string
): Promise<void> {
  await auditStatement(env, feedbackId, actor, action, detail).run();
}
