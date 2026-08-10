# High-Signal Lessons Ledger

Master record of hard-won, repo-wide lessons: full statement, rationale, and history live here. Each lesson also fires as a compressed rule at the surface where it's needed — root `AGENTS.md` for lessons that must fire unconditionally at session start, a nested `AGENTS.md` for surface-specific ones. When editing a lesson, update both the ledger entry and its firing surface. When a lesson graduates to machinery (a CI gate, a script), delete its prose here and note the replacement.

## Unconditional — fire from root `AGENTS.md`

- **Never use bare `self-hosted` for workflows in this repo.** Use GitHub-hosted macOS (`macos-15`) for generic build/test jobs, for the UI smoke lane (`ui-smoke-advisory.yml`), and for agent evidence (`_evidence.yml`); use `[self-hosted, signing-host]` for release/signing/notarization. `signing-host` is the only self-hosted lane — `lume-macos` and `tart-ui` are retired and `.github/actionlint.yaml` rejects them. Perf benchmarks are not a CI lane: they run laptop-local, opt-in per run, per `docs/decisions/perf-measurement-laptop-optin.md`.
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

- **Release version metadata must have one source of truth.** Tag, app version, and packaged artifact version should be validated against each other before a release is created. Graduated to machinery: `scripts/release-version.sh assert-tag-match`, and tag-driven releases fail fast on mismatch (`RELEASING.md`).
- **If the app opens or closes unexpectedly on a dev machine, check the launching process first.** CI/self-hosted runner behavior can look like an app bug.
- **A GUI app launched by launchd sees none of your shell's environment.** Dock/Finder/`open` hand the app launchd's bare environment (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, ~11 vars), so `.env` files, `~/.zshrc`, and a CLI wrapper that shells out to `/usr/bin/open` all fail to reach it; `launchctl setenv` from a login LaunchAgent is the bridge, with Keychain holding any secret at rest. This is why `scripts/launch-dev.sh` env vars work (it spawns the binary directly, `nohup env ... "$DEBUG_BINARY"`) while the `/Applications` copy started from the Dock ignores them. Mechanism, verification commands, and a worked third-party example: `docs/development/macos-gui-app-environment.md`.
