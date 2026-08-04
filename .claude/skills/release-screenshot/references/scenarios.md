# Scenarios

Each named scenario maps to literal UI fixture env vars. The script `scripts/capture.sh` is the single source of truth — this table mirrors its `case` arm. If you edit one, edit both.

## Named scenarios

| Scenario id | `WORKSPACES_UI_FIXTURE_AGENT_STATES` | `WORKSPACES_UI_FIXTURE_COMMAND_STATUSES` | Expected visual |
|-------------|--------------------------------------|----------------------------------------------------|-----------------|
| `phase-1-release` | `feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored` | *(unset)* | `bertram-chat` expanded with `feature-auth` selected (blue thinking dot), `bugfix-422` yellow (awaiting input), `refactor-state` no dot (idle); `bread-builder` collapsed with red bubbled errored dot from `refactor-runtime`; toolbar pill reads "2 need you". Matches `.context/ux-review/release-screenshot.png`. |
| `m6-status-sliver` | *(unset)* | `feature-auth:failed` | `feature-auth` selected with a compact terminal sliver showing a failed `swift test` command, exit `1`, and duration. |
| `attention-only` | `bugfix-422:awaitingInput` | *(unset)* | Only `bugfix-422` shows a yellow dot; toolbar pill reads "1 needs you". |
| `restore-banner` | *(unset)* | *(unset)* | Seeds a synthetic previous-run continuity row (`WORKSPACES_UI_FIXTURE_SEED_RESTORE_BANNER=1` + `WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH=1`) so the cold-start restore banner offers to reopen `feature-auth`. Evidence-lane only — see `docs/development/ui-fixture-mode.md` § "Staging the restore banner"; `capture.sh` doesn't clean data between runs, so it never hits the gap this seeds around. |
| `clean` | *(unset)* | *(unset)* | Baseline sidebar with no agent-state dots; toolbar pill hidden. |

## Inline form

For one-off captures that don't deserve a named scenario, pass the env-var value directly:

```bash
.claude/skills/release-screenshot/scripts/capture.sh \
  --scenario "inline:feature-auth:awaitingInput,bugfix-422:errored" \
  --output /tmp/two-attention.png
```

The string after `inline:` becomes `WORKSPACES_UI_FIXTURE_AGENT_STATES` verbatim. Same parsing rules — comma-separated `workspaceName:state` pairs, whitespace tolerated.

## Supported states

| Token | Resulting `AgentRunState` | Visual |
|-------|---------------------------|--------|
| `idle` | `.idle` | No dot |
| `thinking` | `.thinking` | Blue dot |
| `runningTool` | `.runningTool(name:"Edit", detail:"Models.swift")` | Blue dot (running) |
| `awaitingInput` | `.awaitingInput(reason: .permissionPrompt)` | Yellow dot (contributes to attention count) |
| `errored` | `.errored(category: .toolFailure, message: "Tool failed")` | Red dot (contributes to attention count) |
| `complete` | `.complete` | No dot |

## Supported command statuses

`WORKSPACES_UI_FIXTURE_COMMAND_STATUSES` uses the same comma-separated `workspaceName:status` shape. It creates or activates the matching host terminal session and publishes a synthetic `LastCommandStatus` for the terminal sliver.

| Token | Resulting command status | Visual |
|-------|--------------------------|--------|
| `success` | `swift build`, exit `0` | Green success sliver |
| `failed` | `swift test`, exit `1` | Red failed sliver |
| `running` | running `swift test` | Running sliver |
| `finished` | `git status`, unknown exit code | Neutral finished sliver |

## Available fixture workspaces

These are seeded by `UIFixtureSeeder.seedDataIfNeeded` and are the valid names you can reference in the env var:

- `skills-v13` (under `skills`)
- `feature-auth`, `bugfix-422`, `refactor-state` (under `bertram-chat`)
- `refactor-runtime` (under `bread-builder`)

Names not in this list are logged and skipped at runtime — the rest of the env var still applies.
