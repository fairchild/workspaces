# High-Signal Lessons Ledger

Master record of hard-won, repo-wide lessons: full statement, rationale, and history live here. Each lesson also fires as a compressed rule at the surface where it's needed — root `AGENTS.md` for lessons that must fire unconditionally at session start, a nested `AGENTS.md` for surface-specific ones. When editing a lesson, update both the ledger entry and its firing surface. When a lesson graduates to machinery (a CI gate, a script), delete its prose here and note the replacement.

## Unconditional — fire from root `AGENTS.md`

- **Never use bare `self-hosted` for workflows in this repo.** Use GitHub-hosted macOS (`macos-15`) for generic build/test jobs, `[self-hosted, tart-ui]` for UI/perf automation, `[self-hosted, lume-macos]` for agent execution (preferred, with ubuntu-latest fallback), and `[self-hosted, signing-host]` for release/signing/notarization.
- **Ship a diagnostic probe instead of your third guess.** Terminal arc #306→#309: two guess-fixes merged green and failed in production; one temporary probe (#308) revealed the root cause in a single ship cycle. When you're guessing, stop and instrument.
- **The tracker lags the code — verify before planning from it.** Three grooming/planning passes in a row (2026-06-28 ×2, 2026-07-02) found open issues whose work had already shipped. Before sequencing work from open issues, `rg` the acceptance criteria against the tree; close what's done in the same cycle that ships it (`Closes #N` in every implementing PR).

## Desktop UI — fire from `Sources/AGENTS.md`

- **Keep terminal surfaces nearly chrome-free.** Repo overview pages can carry metadata and actions, but terminal views default to the canvas with minimal surrounding UI.
- **Prefer quiet discoverability over persistent controls.** Avoid right-click-only primary actions, but also avoid always-visible sidebar affordances that add noise. Hover-visible scoped actions are usually the right compromise.
- **Persist selection state by stable IDs, not live SwiftData objects.** Restore and fallback logic should resolve models late and validate them against current data before selection.

## Agent paths — fire from `web-next/AGENTS.md`

- **Vercel `Sandbox.create({env: {...}})` does NOT propagate to `sandbox.runCommand()`.** Write env vars to an `env.sh` and `source` it at the top of the script. See `docs/development/agent-chat-sandbox.md` § "Claude CLI Authentication".
- **"Tests green" ≠ "works in production" for agent paths.** For changes touching `createSandbox`, `restoreSnapshot`, `createTerminalSandbox`, or `streamOutput`, send a real chat message in production and read the agent stream before declaring victory.

## Release and dev-machine ops — ledger only

- **Release version metadata must have one source of truth.** Tag, app version, and packaged artifact version should be validated against each other before a release is created.
- **If the app opens or closes unexpectedly on a dev machine, check the launching process first.** CI/self-hosted runner behavior can look like an app bug.
