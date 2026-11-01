---
status: decided
date: 2026-11-01
decision: launch-record-file-per-handle
related:
  - docs/development/automation-api.md
---

# Agent Launch Record

## Context

`ws launch` and the app share no channel: CLI state is `state.json`, app state is SwiftData, and the automation socket needs an opt-in operator credential. So a launched session was missing from the sidebar, and nothing named its conversation for a later resume. Parallel launchers would also lose updates to one read-modify-write file. Claude's `--session-id` lets the launcher choose the conversation id up front. Bare `--resume` restores the model but not the effort, as tested on claude 2.1.316.

## Decision

Each launch writes one file, `<config>/workspaces-cli/launches/<socket>/<handle>.json`, holding the conversation id and requested model and effort. The app watches that directory and adds rows. The transcript, never the record, answers what actually ran.

## Consequences

- `ws check`, `ws resume` and the app read one fact, and parallel launches cannot collide.
- A record states what was asked for. `verified` needs a turn taken by the current process, so a launch with no prompt stays `ready`.
- Only a plain `claude` command gets an id. Wrappers run, but cannot be checked or resumed.
- Costs: the app and CLI must agree on the config directory, so `XDG_CONFIG_HOME` set for the CLI alone hides records. Adoption also needs the repo tracked by the app.

## Alternatives considered

- Automation route to the app: needs the operator credential, which is opt-in, and fails while the app is closed.
- Entries in `state.json`: one writer wins when launches race.
- Parsing `~/.claude/sessions/<pid>.json`: it has no model or effort, and vanishes with the process.
- Model and effort read from the pane: the status line varies, and only the transcript records what was sent.

## Status

Accepted.
