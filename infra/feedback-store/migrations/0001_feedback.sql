CREATE TABLE IF NOT EXISTS feedback (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  kind TEXT NOT NULL,
  message TEXT NOT NULL,
  contact_email TEXT,
  submitter_login TEXT,
  submitter_id TEXT,
  app_version TEXT NOT NULL,
  os_version TEXT NOT NULL,
  client TEXT NOT NULL,
  ip_hash TEXT,
  status TEXT NOT NULL DEFAULT 'new',
  admin_notes TEXT,
  github_issue_url TEXT,
  attachment_prefix TEXT,
  has_screenshot INTEGER NOT NULL DEFAULT 0,
  has_diagnostics INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_feedback_created_at ON feedback(created_at);
CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status);
CREATE INDEX IF NOT EXISTS idx_feedback_kind ON feedback(kind);
