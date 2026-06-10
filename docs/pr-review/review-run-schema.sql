-- Current managed PR reviewer storage reference.
--
-- This file documents the ReviewRun-centered shape used by the web runtime.
-- The production app creates these tables through Kysely/LibSQL helpers in
-- web/src/lib/agent-runtime/pr-review-runs.ts. Treat this file as an operator
-- and architecture reference, not as a migration.
--
-- Start with docs/pr-review/README.md, then docs/pr-review/architecture.md for
-- diagrams, vocabulary, lifecycle paths, and triage surfaces.

CREATE TABLE managed_pr_review_runs (
  fingerprint text PRIMARY KEY,

  repo_full_name text NOT NULL,
  pr_number integer NOT NULL,
  head_sha text NOT NULL,
  trigger_kind text NOT NULL,
  trigger_source_id text NOT NULL,
  reviewer_config_hash text NOT NULL,

  -- Managed-agent execution lifecycle:
  -- started | completed | failed | superseded
  status text NOT NULL,
  session_id text,
  session_started_at text,

  created_at text NOT NULL,
  updated_at text NOT NULL,

  -- Execution failure summary. Messages are sanitized and bounded before
  -- storage.
  error text,
  failure_kind text,
  failure_message text,
  failure_retryable integer,
  failed_at text,

  -- GitHub projection lifecycle:
  -- pending | projected | failed | superseded
  projection_status text,
  projection_updated_at text,
  projection_error text,
  github_review_id text,

  -- Validated review intent captured from the completed managed-agent output.
  review_intent_event text,
  review_intent_body text,
  review_intent_labels text,
  review_intent_recorded_at text,

  -- Active-run coalescing. active_claim_key is unique while a run is active
  -- for one repo, PR, and reviewer config.
  active_claim_key text,
  coalesced_head_sha text,
  coalesced_trigger_kind text,
  coalesced_trigger_source_id text,
  coalesced_at text
);

CREATE INDEX idx_managed_pr_review_runs_pr
  ON managed_pr_review_runs (repo_full_name, pr_number);

CREATE UNIQUE INDEX ux_managed_pr_review_runs_active_claim
  ON managed_pr_review_runs (active_claim_key);

CREATE TABLE managed_pr_review_projections (
  projection_id text PRIMARY KEY,
  run_fingerprint text NOT NULL,

  -- Current projection types:
  -- github_status | github_review
  projection_type text NOT NULL,
  projection_key text NOT NULL,

  desired_payload_hash text NOT NULL,
  desired_payload text NOT NULL,

  -- Ledger state:
  -- pending | projecting | projected | failed | superseded
  state text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  last_attempted_at text,
  observed_external_id text,
  error_kind text,
  error_text text,

  created_at text NOT NULL,
  updated_at text NOT NULL
);

CREATE UNIQUE INDEX ux_managed_pr_review_projections_desired
  ON managed_pr_review_projections (
    run_fingerprint,
    projection_type,
    projection_key,
    desired_payload_hash
  );

CREATE INDEX idx_managed_pr_review_projections_run
  ON managed_pr_review_projections (run_fingerprint);

CREATE INDEX idx_managed_pr_review_projections_state
  ON managed_pr_review_projections (state, updated_at);
