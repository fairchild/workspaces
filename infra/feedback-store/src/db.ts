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
}
