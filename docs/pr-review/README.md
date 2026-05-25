# Managed PR Review

This directory is the home for managed PR reviewer design and operations docs.

- [`pr-reviewer.md`](pr-reviewer.md): deployed runtime, webhook ingress,
  broker, health checks, and debugging.
- [`review-run-schema.sql`](review-run-schema.sql): commented Postgres DDL
  sketch for the target `ReviewRun` source-of-truth model, with example rows.

The model should stay simple: a `ReviewRun` row is the durable source of truth.
GitHub statuses, reviews, labels, diagnostic comments, health checks, and
dashboard pages are projections that can be recreated or repaired from that row.

## Source Of Truth

```
GitHub webhook / manual retry
|
v
+-------------------------+
| ReviewRun               |
|-------------------------|
| repo + PR + head        |
| trigger + fingerprint   |
| state + timestamps      |
| agent session id        |
| validated intent        |
| error details           |
+-----------+-------------+
|
| desired external state
v
+-------------------------+
| ReviewRunProjection     |
|-------------------------|
| github status           |
| github review           |
| github labels           |
| diagnostic comment      |
+-----------+-------------+
|
| apply / observe / repair
v
+-------------------------+
| GitHub                  |
|-------------------------|
| WorkSpaces status       |
| PR review               |
| labels/comments         |
+-------------------------+
```

This removes ambiguity. Operators should ask "what does the run say?" first,
then ask whether GitHub matches it.

## State Machine

```
+--------+    session starts    +---------+
| queued | -------------------> | running |
+---+----+                      +----+----+
|                                |
| setup failure                  | valid review intent
v                                v
+--------+   parse/apply    +-----------+   projections   +-----------+
| failed | <--------------- | completed | --------------> | published |
+--------+     failure      +-----+-----+     applied     +-----------+
^                                |
| projection drift               | newer head/config
|                                v
|                          +------------+
+--------------------------| superseded |
+------------+
```

The state field should stay small. Retry counters, reconcile timestamps, and
projection status are operational metadata, not extra run states.

## Relationships

```
review_runs
id PK
fingerprint UNIQUE
repo_full_name, pr_number, head_sha
state
anthropic_session_id
intent_event, intent_body, intent_json
error_code, error_message
|
| 1-to-many
v
review_run_projections
run_id FK
kind: github_status | github_review | github_issue_comment | github_labels
projection_key
state: missing | applying | applied | failed | drifted | not_needed
desired_payload
observed_payload

review_runs
|
| 1-to-many
v
review_run_transitions
run_id FK
from_state, to_state
event_name, actor, reason
```

The transition table is an audit log. The projection table is a repair ledger.
Neither should replace the current state on `review_runs`.
