export interface Env {
  FEEDBACK_DB: D1Database;
  FEEDBACK_BUCKET: R2Bucket;
  JWT_SIGNING_SECRET: string;
  ADMIN_SESSION_SECRET: string;
  ADMIN_ALLOWLIST: string;
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  GITHUB_ISSUE_TOKEN?: string;
  GITHUB_OWNER?: string;
  GITHUB_REPO?: string;
  GITHUB_API_BASE?: string;
  FEEDBACK_IP_HASH_SALT?: string;
  POSTS_PER_HOUR?: string;
}

export interface FeedbackAuditRow {
  id: number;
  feedback_id: string;
  at: number;
  actor: string;
  action: string;
  detail: string | null;
}

export interface FeedbackPayload {
  kind: "bug" | "idea" | "feedback";
  message: string;
  contact_email?: string;
  app_version: string;
  os_version: string;
  client: string;
  honeypot?: string;
}

export interface FeedbackRow {
  id: string;
  created_at: number;
  kind: "bug" | "idea" | "feedback";
  message: string;
  contact_email: string | null;
  submitter_login: string | null;
  submitter_id: string | null;
  app_version: string;
  os_version: string;
  client: string;
  ip_hash: string | null;
  status: string;
  admin_notes: string | null;
  github_issue_url: string | null;
  attachment_prefix: string | null;
  has_screenshot: number;
  has_diagnostics: number;
}
