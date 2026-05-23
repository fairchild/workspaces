# Scenarios

Each named scenario maps to one literal value of `WORKSPACES_UI_FIXTURE_AGENT_STATES`. The script `scripts/capture.sh` is the single source of truth — this table mirrors its `case` arm. If you edit one, edit both.

## Named scenarios

| Scenario id | `WORKSPACES_UI_FIXTURE_AGENT_STATES` | Expected visual |
|-------------|--------------------------------------|-----------------|
| `phase-1-release` | `feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored` | `bertram-chat` expanded with `feature-auth` selected (blue thinking dot), `bugfix-422` yellow (awaiting input), `refactor-state` no dot (idle); `bread-builder` collapsed with red bubbled errored dot from `refactor-runtime`; toolbar pill reads "2 need you". Matches `.context/ux-review/release-screenshot.png`. |
| `attention-only` | `bugfix-422:awaitingInput` | Only `bugfix-422` shows a yellow dot; toolbar pill reads "1 needs you". |
| `clean` | *(unset)* | Baseline sidebar with no agent-state dots; toolbar pill hidden. |

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

## Available fixture workspaces

These are seeded by `UIFixtureSeeder.seedDataIfNeeded` and are the valid names you can reference in the env var:

- `skills-v13` (under `skills`)
- `feature-auth`, `bugfix-422`, `refactor-state` (under `bertram-chat`)
- `refactor-runtime` (under `bread-builder`)

Names not in this list are logged and skipped at runtime — the rest of the env var still applies.
