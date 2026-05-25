---
status: done
category: plan
resolution: deferred-design
topic: agent-runtime
priority: 3
description: Design notes for a host-owned AgentEvent log used for cold-start state recovery. Deferred — the architecture intentionally keeps transcripts as transcript data only. Revisit if cold-start recovery becomes necessary.
---

# Agent Event Log Recovery

Status: Deferred

## Context

The first transcript recovery design read Claude Code JSONL transcripts back into
`AgentSessionRegistry` on app launch. That made Channel 4 serve two purposes:
conversation replay and state reconstruction. The architecture now keeps
transcripts as transcript data only.

## Better Direction

If cold-start state recovery becomes necessary, persist the host's own normalized
`AgentEvent` stream as it is received from Channel 1 and Channel 2. Recovery
should replay WorkSpaces-owned events, not infer app state from Claude's
conversation transcript format.

## Why

- `AgentEvent` is the registry contract; transcript records are a display/audit
  format owned by Claude Code.
- A host-owned log can include routing metadata such as `hostSessionID`, origin,
  and timestamps without guessing.
- Replay can use the same `AgentSessionRegistry.apply(events:for:origin:)`
  surface as live ingestion.

## Acceptance Criteria

- The log format is append-only, versioned, and bounded by retention policy.
- Recovery never blocks app launch or the terminal creation path.
- Replay is batched enough to avoid SwiftUI churn and is covered by a perf test.
- The conversation log remains backed by `TranscriptReader`; recovery does not
  require parsing transcript JSONL.
