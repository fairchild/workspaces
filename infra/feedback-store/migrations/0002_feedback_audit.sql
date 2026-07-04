-- Append-only audit trail for feedback triage actions (currently: publish).
-- The admin UI writes here so every publish carries an accountable actor.
-- Mirrors ensureSchema() in db.ts.
CREATE TABLE IF NOT EXISTS feedback_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feedback_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT
);

CREATE INDEX IF NOT EXISTS idx_feedback_audit_feedback_id ON feedback_audit(feedback_id);
