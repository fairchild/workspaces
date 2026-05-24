-- Postgres design sketch for the managed PR reviewer state machine.
--
-- This file is intentionally documentation, not a production migration. The
-- deployed web app currently uses LibSQL/Kysely, but the normalized Postgres
-- shape below is the target model: ReviewRun is the source of truth, while
-- GitHub statuses, GitHub reviews, labels, and diagnostic comments are
-- projections that can be repaired from ReviewRun state.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS managed_review;

COMMENT ON SCHEMA managed_review IS
  'Durable state for managed PR review runs. GitHub state is a projection of these rows.';

DO $$
BEGIN
  CREATE TYPE managed_review.review_run_state AS ENUM (
    'queued',
    'running',
    'completed',
    'published',
    'failed',
    'superseded'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

COMMENT ON TYPE managed_review.review_run_state IS
  'Small state machine for one managed review attempt.';

DO $$
BEGIN
  CREATE TYPE managed_review.review_trigger_kind AS ENUM (
    'pr_opened',
    'pr_reopened',
    'pr_ready_for_review',
    'pr_synchronized',
    'pr_body_edited',
    'pr_base_edited',
    'evidence_comment',
    'manual_retry',
    'superseded_retry'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

COMMENT ON TYPE managed_review.review_trigger_kind IS
  'External or operator event that asked for a managed review run.';

DO $$
BEGIN
  CREATE TYPE managed_review.review_intent_event AS ENUM (
    'approve',
    'request_changes',
    'comment'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

COMMENT ON TYPE managed_review.review_intent_event IS
  'Validated GitHub review event requested by the managed agent.';

DO $$
BEGIN
  CREATE TYPE managed_review.review_projection_kind AS ENUM (
    'github_status',
    'github_review',
    'github_issue_comment',
    'github_labels'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

COMMENT ON TYPE managed_review.review_projection_kind IS
  'Kind of external GitHub object projected from a ReviewRun.';

DO $$
BEGIN
  CREATE TYPE managed_review.review_projection_state AS ENUM (
    'missing',
    'applying',
    'applied',
    'failed',
    'drifted',
    'not_needed'
  );
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

COMMENT ON TYPE managed_review.review_projection_state IS
  'Observed state of one GitHub projection for a ReviewRun.';

CREATE TABLE IF NOT EXISTS managed_review.review_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Idempotency key for the logical run. This is usually a hash of repo, PR,
  -- head SHA, trigger kind/source, and reviewer config hash.
  fingerprint text NOT NULL UNIQUE,

  repo_full_name text NOT NULL,
  pr_number integer NOT NULL CHECK (pr_number > 0),
  head_sha text NOT NULL CHECK (head_sha ~ '^[0-9a-f]{40}$'),
  head_ref text NOT NULL,
  base_ref text NOT NULL,
  reviewer_config_hash text NOT NULL,

  -- The only state field operators should need to reason about.
  state managed_review.review_run_state NOT NULL DEFAULT 'queued',

  trigger_kind managed_review.review_trigger_kind NOT NULL,
  trigger_source_id text NOT NULL,
  trigger_delivery_id text,
  trigger_url text,

  -- Retry/supersession relationships keep manual repair explicit instead of
  -- reusing rows or hiding history.
  retry_of_run_id uuid REFERENCES managed_review.review_runs(id),
  superseded_by_run_id uuid REFERENCES managed_review.review_runs(id),

  -- Managed-agent execution identity. This is present once the run is running.
  anthropic_session_id text UNIQUE,
  agent_id text,
  environment_id text,
  model text NOT NULL DEFAULT 'claude-opus-4-6',

  -- Validated review intent captured from the completed managed-agent session.
  intent_event managed_review.review_intent_event,
  intent_body text,
  intent_labels text[] NOT NULL DEFAULT '{}',
  intent_json jsonb,

  -- Diagnostic material from the managed-agent final output. Keep this
  -- bounded in application code and treat it as untrusted text when rendering.
  diagnostic_output text,

  -- GitHub review projection summary. The detailed projection rows below are
  -- the repair ledger; these columns make the common success path easy to read.
  github_review_id text,
  github_review_url text,

  queued_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  published_at timestamptz,
  failed_at timestamptz,
  superseded_at timestamptz,

  next_reconcile_at timestamptz NOT NULL DEFAULT now(),
  last_reconcile_at timestamptz,
  reconcile_attempts integer NOT NULL DEFAULT 0 CHECK (reconcile_attempts >= 0),

  error_code text,
  error_message text,
  error_detail jsonb NOT NULL DEFAULT '{}'::jsonb,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT review_runs_repo_full_name_shape
    CHECK (repo_full_name ~ '^[^/]+/[^/]+$'),
  CONSTRAINT review_runs_retry_not_self
    CHECK (retry_of_run_id IS NULL OR retry_of_run_id <> id),
  CONSTRAINT review_runs_superseded_not_self
    CHECK (superseded_by_run_id IS NULL OR superseded_by_run_id <> id),
  CONSTRAINT review_runs_running_has_session
    CHECK (state <> 'running' OR (anthropic_session_id IS NOT NULL AND started_at IS NOT NULL)),
  CONSTRAINT review_runs_completed_has_intent
    CHECK (state NOT IN ('completed', 'published') OR (intent_event IS NOT NULL AND intent_body IS NOT NULL AND completed_at IS NOT NULL)),
  CONSTRAINT review_runs_published_has_review
    CHECK (state <> 'published' OR (github_review_url IS NOT NULL AND published_at IS NOT NULL)),
  CONSTRAINT review_runs_failed_has_error
    CHECK (state <> 'failed' OR (failed_at IS NOT NULL AND error_code IS NOT NULL)),
  CONSTRAINT review_runs_superseded_has_target
    CHECK (state <> 'superseded' OR (superseded_at IS NOT NULL AND superseded_by_run_id IS NOT NULL))
);

COMMENT ON TABLE managed_review.review_runs IS
  'One durable managed reviewer attempt. This row, not GitHub, is the source of truth.';
COMMENT ON COLUMN managed_review.review_runs.fingerprint IS
  'Stable idempotency key for a trigger/config/head combination.';
COMMENT ON COLUMN managed_review.review_runs.state IS
  'Current state-machine state. Valid transitions should happen in application code and be audited in review_run_transitions.';
COMMENT ON COLUMN managed_review.review_runs.trigger_source_id IS
  'Webhook delivery id, comment id, head SHA, or operator retry id that caused this run.';
COMMENT ON COLUMN managed_review.review_runs.retry_of_run_id IS
  'Previous failed or superseded run when this row is an explicit retry.';
COMMENT ON COLUMN managed_review.review_runs.superseded_by_run_id IS
  'Newer run that made this run obsolete.';
COMMENT ON COLUMN managed_review.review_runs.intent_json IS
  'Raw validated structured intent, stored for replay/debugging.';
COMMENT ON COLUMN managed_review.review_runs.diagnostic_output IS
  'Untrusted managed-agent output excerpt for failure comments and operator diagnosis.';
COMMENT ON COLUMN managed_review.review_runs.next_reconcile_at IS
  'Scheduler hint for the reconciler; not semantic state.';
COMMENT ON COLUMN managed_review.review_runs.error_detail IS
  'Structured failure metadata, such as HTTP status, parser reason, or projection payload hash.';

-- Prevent two active runs from competing to publish a review for the same PR
-- head/config. Terminal states may coexist for history and retries.
CREATE UNIQUE INDEX IF NOT EXISTS review_runs_one_active_per_head
  ON managed_review.review_runs (repo_full_name, pr_number, head_sha, reviewer_config_hash)
  WHERE state IN ('queued', 'running', 'completed');

CREATE INDEX IF NOT EXISTS review_runs_reconcile_queue
  ON managed_review.review_runs (next_reconcile_at, state)
  WHERE state IN ('queued', 'running', 'completed', 'failed');

CREATE INDEX IF NOT EXISTS review_runs_pr_lookup
  ON managed_review.review_runs (repo_full_name, pr_number, created_at DESC);

CREATE TABLE IF NOT EXISTS managed_review.review_run_transitions (
  id bigserial PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES managed_review.review_runs(id) ON DELETE CASCADE,
  from_state managed_review.review_run_state,
  to_state managed_review.review_run_state NOT NULL,
  event_name text NOT NULL,
  actor text NOT NULL DEFAULT 'system',
  reason text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE managed_review.review_run_transitions IS
  'Append-only audit log of ReviewRun state changes.';
COMMENT ON COLUMN managed_review.review_run_transitions.event_name IS
  'Domain event, such as trigger.accepted, session.started, intent.completed, projection.published, or run.failed.';
COMMENT ON COLUMN managed_review.review_run_transitions.actor IS
  'Component or operator responsible for the transition.';
COMMENT ON COLUMN managed_review.review_run_transitions.metadata IS
  'Small structured context for diagnosis; never store secrets.';

CREATE INDEX IF NOT EXISTS review_run_transitions_run_time
  ON managed_review.review_run_transitions (run_id, created_at);

CREATE TABLE IF NOT EXISTS managed_review.review_run_projections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES managed_review.review_runs(id) ON DELETE CASCADE,
  kind managed_review.review_projection_kind NOT NULL,

  -- Stable per-run key. Examples: WorkSpaces Managed Review, final-review,
  -- diagnostic-comment, labels.
  projection_key text NOT NULL,
  state managed_review.review_projection_state NOT NULL DEFAULT 'missing',

  desired_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  desired_payload_hash text,

  github_id text,
  github_url text,
  observed_payload jsonb NOT NULL DEFAULT '{}'::jsonb,

  applied_at timestamptz,
  observed_at timestamptz,
  last_error_code text,
  last_error_message text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT review_run_projections_failed_has_error
    CHECK (state <> 'failed' OR last_error_code IS NOT NULL),
  CONSTRAINT review_run_projections_applied_has_observation
    CHECK (state <> 'applied' OR (applied_at IS NOT NULL AND observed_at IS NOT NULL))
);

COMMENT ON TABLE managed_review.review_run_projections IS
  'GitHub objects derived from ReviewRun state. The reconciler can recreate or repair these rows.';
COMMENT ON COLUMN managed_review.review_run_projections.projection_key IS
  'Human-stable key that distinguishes projections of the same kind for one run.';
COMMENT ON COLUMN managed_review.review_run_projections.desired_payload IS
  'Canonical payload the reconciler wants GitHub to have.';
COMMENT ON COLUMN managed_review.review_run_projections.observed_payload IS
  'Last GitHub state observed by the reconciler.';
COMMENT ON COLUMN managed_review.review_run_projections.state IS
  'Projection health relative to ReviewRun state: missing, applied, failed, drifted, or not needed.';

CREATE UNIQUE INDEX IF NOT EXISTS review_run_projections_one_key
  ON managed_review.review_run_projections (run_id, kind, projection_key);

CREATE INDEX IF NOT EXISTS review_run_projections_repair
  ON managed_review.review_run_projections (state, updated_at)
  WHERE state IN ('missing', 'failed', 'drifted');

-- Health should become a view over unreconciled ReviewRuns, not a scrape of
-- GitHub statuses first. GitHub checks are projection verification only.
CREATE OR REPLACE VIEW managed_review.review_run_health AS
SELECT
  r.id,
  r.repo_full_name,
  r.pr_number,
  r.head_sha,
  r.state,
  r.error_code,
  r.error_message,
  r.next_reconcile_at,
  r.last_reconcile_at,
  count(p.id) FILTER (WHERE p.state IN ('missing', 'failed', 'drifted')) AS unhealthy_projection_count,
  max(p.updated_at) FILTER (WHERE p.state IN ('missing', 'failed', 'drifted')) AS last_unhealthy_projection_at
FROM managed_review.review_runs r
LEFT JOIN managed_review.review_run_projections p ON p.run_id = r.id
WHERE r.state IN ('queued', 'running', 'completed', 'failed')
GROUP BY
  r.id,
  r.repo_full_name,
  r.pr_number,
  r.head_sha,
  r.state,
  r.error_code,
  r.error_message,
  r.next_reconcile_at,
  r.last_reconcile_at;

COMMENT ON VIEW managed_review.review_run_health IS
  'Operator-facing queue of runs that still need reconciliation or explicit attention.';

-- ---------------------------------------------------------------------------
-- Example rows
-- ---------------------------------------------------------------------------
-- The examples are executable against an empty database. They are not seed data.

-- Example 1: a completed and published approval. GitHub can be repaired from
-- this run because the validated intent and projection payloads are durable.
INSERT INTO managed_review.review_runs (
  id,
  fingerprint,
  repo_full_name,
  pr_number,
  head_sha,
  head_ref,
  base_ref,
  reviewer_config_hash,
  state,
  trigger_kind,
  trigger_source_id,
  trigger_url,
  anthropic_session_id,
  agent_id,
  environment_id,
  intent_event,
  intent_body,
  intent_labels,
  intent_json,
  github_review_id,
  github_review_url,
  queued_at,
  started_at,
  completed_at,
  published_at
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  'sha256:f4a7-review-run-published-example',
  'fairchild/workspaces',
  504,
  '1454644ee9f36f802206d305b2c58f9b2b36415a',
  'codex-managed-review-parser',
  'main',
  'reviewer-config:claude-opus-4-6:2026-05-24',
  'published',
  'pr_ready_for_review',
  'head-1454644ee9f36f802206d305b2c58f9b2b36415a',
  'https://github.com/fairchild/workspaces/pull/504',
  'sesn_01examplepublished',
  'agent_pr_reviewer',
  'env_pr_reviewer',
  'approve',
  'Approve - parser hardening is focused and covered by regression tests.',
  ARRAY['area: platform', 'web'],
  '{"event":"APPROVE","labels":["area: platform","web"]}'::jsonb,
  'PRR_kwDOExampleReview',
  'https://github.com/fairchild/workspaces/pull/504#pullrequestreview-1',
  '2026-05-24T06:07:46Z',
  '2026-05-24T06:07:47Z',
  '2026-05-24T06:12:30Z',
  '2026-05-24T06:13:00Z'
);

INSERT INTO managed_review.review_run_projections (
  run_id,
  kind,
  projection_key,
  state,
  desired_payload,
  desired_payload_hash,
  github_id,
  github_url,
  observed_payload,
  applied_at,
  observed_at
) VALUES
  (
    '11111111-1111-4111-8111-111111111111',
    'github_status',
    'WorkSpaces Managed Review',
    'applied',
    '{"state":"success","context":"WorkSpaces Managed Review","description":"Managed review posted."}'::jsonb,
    'sha256:status-success-example',
    'status:1454644:WorkSpaces Managed Review',
    'https://github.com/fairchild/workspaces/pull/504',
    '{"state":"success","context":"WorkSpaces Managed Review"}'::jsonb,
    '2026-05-24T06:13:00Z',
    '2026-05-24T06:13:01Z'
  ),
  (
    '11111111-1111-4111-8111-111111111111',
    'github_review',
    'final-review',
    'applied',
    '{"event":"APPROVE","body":"Approve - parser hardening is focused and covered by regression tests."}'::jsonb,
    'sha256:review-approve-example',
    'PRR_kwDOExampleReview',
    'https://github.com/fairchild/workspaces/pull/504#pullrequestreview-1',
    '{"state":"APPROVED","commit_id":"1454644ee9f36f802206d305b2c58f9b2b36415a"}'::jsonb,
    '2026-05-24T06:13:00Z',
    '2026-05-24T06:13:01Z'
  );

INSERT INTO managed_review.review_run_transitions (
  run_id,
  from_state,
  to_state,
  event_name,
  actor,
  reason,
  metadata
) VALUES
  ('11111111-1111-4111-8111-111111111111', NULL, 'queued', 'trigger.accepted', 'webhook', 'PR moved to ready for review', '{}'::jsonb),
  ('11111111-1111-4111-8111-111111111111', 'queued', 'running', 'session.started', 'reconciler', 'Managed-agent session created', '{"session_id":"sesn_01examplepublished"}'::jsonb),
  ('11111111-1111-4111-8111-111111111111', 'running', 'completed', 'intent.completed', 'reconciler', 'Validated APPROVE intent captured', '{}'::jsonb),
  ('11111111-1111-4111-8111-111111111111', 'completed', 'published', 'projection.published', 'reconciler', 'GitHub review and status applied', '{}'::jsonb);

-- Example 2: a completed session whose output could not be converted into a
-- final GitHub review. The failed run plus status/comment projections make the
-- problem explicit; operators do not have to infer it from GitHub status alone.
INSERT INTO managed_review.review_runs (
  id,
  fingerprint,
  repo_full_name,
  pr_number,
  head_sha,
  head_ref,
  base_ref,
  reviewer_config_hash,
  state,
  trigger_kind,
  trigger_source_id,
  trigger_url,
  anthropic_session_id,
  intent_json,
  diagnostic_output,
  queued_at,
  started_at,
  completed_at,
  failed_at,
  error_code,
  error_message,
  error_detail
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'sha256:8db1-review-run-failed-example',
  'fairchild/workspaces',
  504,
  '1454644ee9f36f802206d305b2c58f9b2b36415a',
  'codex-managed-review-parser',
  'main',
  'reviewer-config:claude-opus-4-6:2026-05-24',
  'failed',
  'manual_retry',
  'comment-4527593416',
  'https://github.com/fairchild/workspaces/pull/504#issuecomment-4527593416',
  'sesn_01examplefailed',
  '{"raw":"agent returned a review intent that production could not parse"}'::jsonb,
  'The managed reviewer completed, but the production parser stopped at an embedded fenced-code marker.',
  '2026-05-24T06:21:56Z',
  '2026-05-24T06:21:58Z',
  '2026-05-24T06:28:40Z',
  '2026-05-24T06:28:58Z',
  'intent_json_parse_failed',
  'No valid PR review intent JSON found: unterminated string in JSON body',
  '{"parser":"legacy_lazy_fence_regex","repair":"deploy line-delimited fence parser"}'::jsonb
);

INSERT INTO managed_review.review_run_projections (
  run_id,
  kind,
  projection_key,
  state,
  desired_payload,
  desired_payload_hash,
  github_id,
  github_url,
  observed_payload,
  applied_at,
  observed_at,
  last_error_code,
  last_error_message
) VALUES
  (
    '22222222-2222-4222-8222-222222222222',
    'github_status',
    'WorkSpaces Managed Review',
    'applied',
    '{"state":"failure","context":"WorkSpaces Managed Review","description":"Managed review failed before posting."}'::jsonb,
    'sha256:status-failure-example',
    'status:1454644:WorkSpaces Managed Review',
    'https://github.com/fairchild/workspaces/pull/504',
    '{"state":"failure","context":"WorkSpaces Managed Review"}'::jsonb,
    '2026-05-24T06:28:58Z',
    '2026-05-24T06:28:59Z',
    NULL,
    NULL
  ),
  (
    '22222222-2222-4222-8222-222222222222',
    'github_issue_comment',
    'diagnostic-comment',
    'applied',
    '{"body":"Managed review publication failed. See escaped diagnostic output."}'::jsonb,
    'sha256:diagnostic-comment-example',
    'IC_kwDOExampleDiagnostic',
    'https://github.com/fairchild/workspaces/pull/504#issuecomment-operator-note',
    '{"body_prefix":"Managed review publication failed"}'::jsonb,
    '2026-05-24T06:28:58Z',
    '2026-05-24T06:28:59Z',
    NULL,
    NULL
  );

INSERT INTO managed_review.review_run_transitions (
  run_id,
  from_state,
  to_state,
  event_name,
  actor,
  reason,
  metadata
) VALUES
  ('22222222-2222-4222-8222-222222222222', NULL, 'queued', 'trigger.accepted', 'operator', 'Manual retry requested after failed projection', '{"comment_id":"4527593416"}'::jsonb),
  ('22222222-2222-4222-8222-222222222222', 'queued', 'running', 'session.started', 'reconciler', 'Managed-agent session created', '{"session_id":"sesn_01examplefailed"}'::jsonb),
  ('22222222-2222-4222-8222-222222222222', 'running', 'failed', 'run.failed', 'reconciler', 'Completed output could not be parsed by deployed broker', '{"error_code":"intent_json_parse_failed"}'::jsonb);
