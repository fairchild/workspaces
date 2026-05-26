---
status: done
category: plan
resolution: deferred-design
topic: agent-runtime
priority: 3
description: Design notes for a host-owned `claude -p` runner (workspace warm-up, scheduled tasks, sidebar quick actions). Removed from the shipped integration; preserved here as a design doc. Revisit when there's a concrete UI/automation surface, a clear permission model, and a product decision on headless-vs-interactive history.
---

# Headless Claude Programmatic Runner

Status: Deferred

## Context

The original Claude Code integration included a fifth channel: a host-owned
`claude -p` runner for workspace warm-up, scheduled tasks, and future sidebar
quick actions. That work was removed from the shipped integration because it was
not part of the live terminal signal path and it introduced a second execution
model before the product had a committed workflow for it.

## Why It Was Removed

- It did not feed `AgentSessionRegistry` in the same way as hooks, status-line,
  and OSC.
- It added process streaming, NDJSON parsing, session persistence, resume
  semantics, setup-file schemas, and tests without a visible product surface.
- Workspace creation should not implicitly run an agent unless the UX, safety
  model, and failure reporting are explicit.

## Revisit When

- There is a concrete UI or automation surface that needs host-owned Claude
  execution.
- The permission model is clear: which prompts can run, with which tools, under
  whose credentials, and with what audit trail.
- The product decision says whether headless runs are separate from interactive
  sessions or should appear in the same conversation/history model.

## Acceptance Criteria For A Future Implementation

- A dedicated module owns process lifetime, cancellation, streaming parse, and
  resume state.
- No workspace creation side effect runs Claude unless the user opted into that
  specific automation.
- The stream parser is tested against real `--output-format stream-json`
  fixtures.
- Headless run state has its own UI surface and does not pretend to be an
  interactive terminal session.
- The implementation includes a smoke test that runs against a fixture `claude`
  executable without requiring real credentials.
