# Extending: adding a new scenario

1. **Pick a scenario id.** Kebab-case, descriptive of the visual: `attention-overflow`, `bertram-only-clean`, etc.
2. **Add a `case` arm to `scripts/capture.sh`** in the same block as `phase-1-release`. The arm sets `agent_states="..."`.
3. **Document the scenario in `references/scenarios.md`** — same row format (id, env value, expected visual). Drift between the script and the doc is the most common bug in this surface, so treat the script as the source of truth and mirror it line-for-line.
4. **Verify** by running `.claude/skills/release-screenshot/scripts/capture.sh <new-id>` and opening the resulting PNG. Iterate the env-var value until the screenshot matches your intent, then commit.

## Adding a new fixture workspace

If your scenario needs a workspace that doesn't exist in the fixture, add it to `UIFixtureSeeder.seedDataIfNeeded(in:)` in `Sources/WorkspaceManager/App/UIFixtureSeeder.swift`. Keep the path namespace consistent (under `~/code/workspaces/<repo>/<workspace>/`) — the path doesn't need to exist on disk, the fixture model store accepts any string.

After adding the workspace, list it in `references/scenarios.md` under "Available fixture workspaces" so future scenario authors know it's available.

## Adding a new agent run-state token

Tokens live in `UIFixtureSeeder.runState(for:)`. The full set of `AgentRunState` cases is `idle`, `thinking`, `runningTool`, `awaitingInput`, `complete`, `errored`. If you want a variant (e.g. `awaitingInput` with `.idlePrompt` reason instead of `.permissionPrompt`), add a new token (`awaitingIdle`) that maps to the variant you need. Document it in `references/scenarios.md` under "Supported states".

## Limits

- Terminal scrollback isn't seeded. The screenshot will show whatever the live shell prompt produces.
- Repo-overview content (PR list, recent commits) isn't seeded; it'll be empty unless the underlying git repo exists at the workspace path.
- Selection: the auto-selection picks the most-recently-accessed workspace at boot. If you need a *specific* workspace selected for a screenshot, either touch its `lastAccessedAt` in the seeder, or drive a `cliclick` selection from a follow-up scenario block. Prefer the data-driven route.

If you find yourself reaching for `cliclick` in `capture.sh`, ask first whether the same outcome is reachable by extending the fixture seeder. The point of this skill is purely-data-driven setup; UI automation is the escape hatch, not the path.
