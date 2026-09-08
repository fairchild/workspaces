# Contributing

Thanks for contributing to WorkSpaces.

## Prerequisites

- macOS 14.0+ (Sonoma or newer)
- Xcode 15.0+ or Swift 5.10+
- [mise](https://mise.jdx.dev/) (toolchain management)

## Local Setup

From repo root:

```bash
./scripts/setup  # first-run: tools, dependencies, env links, and prek hooks
```

After the first-run bootstrap, use the root `mise` tasks for normal development:

```bash
mise run build-ghosttykit  # one-time or after Ghostty pin changes
mise run build
mise run test
```

To refresh git hooks without running full setup:

```bash
mise run hooks-install
```

The underlying script path remains `./scripts/setup --hooks-only`.

To run the app in dev mode (isolated data directory):

```bash
mise run dev-launch
```

`launch-dev.sh` runs the debug binary from `.build/` with an isolated local data root. Useful options:

```bash
mise run dev-launch -- --no-build       # skip rebuild, launch existing binary
mise run dev-launch -- --no-activate    # don't steal foreground focus
```

If your shell restricts writes to `~/Library/Application Support`, set a custom data dir:

```bash
WORKSPACES_DATA_DIR="$PWD/.workspacemanager-data" swift run WorkspaceManager
```

## Daily Development Checks

Run before and after non-trivial changes:

```bash
mise run check
```

`mise run check` runs Swift format lint, `swift build`, and `swift test`.

## Local Install Workflow

Replace your installed app in `/Applications` with your current local build:

```bash
./scripts/install-local.sh
```

This also links `workspaces` into the first writable directory already on your `PATH` unless you pass `--no-cli-link`.

Useful options:

```bash
./scripts/install-local.sh --no-build --no-open
./scripts/install-local.sh --signed
./scripts/install-local.sh --dest ~/Applications/WorkSpaces.app
./scripts/install-local.sh --cli-link ~/.local/bin/workspaces
```

## CLI Development

```bash
swift run workspaces help
```

## Project Structure

```text
workspaces/
  Package.swift
  Sources/
    WorkspaceManager/        # Main app (SwiftUI + AppKit)
    WorkspaceManagerCore/    # Core models + services
    WorkspaceManagerCLI/     # CLI entrypoint
  Tests/                     # Unit tests
  scripts/                   # Build/release tooling
```

## Pull Request Guidance

1. Keep scope focused and prefer incremental, testable changes.
2. Add or update tests when behavior changes.
3. Run local checks (`mise run check`, or focused build/test commands when appropriate).
4. Include a concise summary of behavior changes and verification results in the PR.
5. Write the body from `.github/pull_request_template.md` rather than from memory, and check it before publishing:

   ```bash
   cp .github/pull_request_template.md /tmp/pr-body.md   # then fill it in
   uv run --script scripts/pr-readiness.py --body-file /tmp/pr-body.md
   gh pr create --body-file /tmp/pr-body.md
   ```

   The preflight runs the same checks as the `PR Readiness` gate and prints the same failures, so a missing `## Mergeability` section costs one re-edit instead of a CI round trip.

## CI Runner Lanes

Every lane that needs macOS runs on GitHub-hosted `macos-26`: generic lint/build/test CI, the behavioral UI smoke lane (`ui-smoke-advisory.yml`), the agent evidence lane (`_evidence.yml`), and release/signing/notarization. Agent and metadata jobs run on `ubuntu-latest`. Generic CI is path-scoped to product, test, build, and release inputs so docs, backlog, skill, and changelog-only pushes do not consume the hosted macOS queue. No workflow targets a self-hosted runner.

Performance benchmarks are not a CI lane. They run on the owner's laptop, opt-in per run, because the contract budgets are `Mac16,13`-derived and no cloud runner can carry them — see [docs/decisions/perf-measurement-laptop-optin.md](./docs/decisions/perf-measurement-laptop-optin.md) for the protocol and the measurement-hygiene preconditions.

No self-hosted runner is registered. `blue-workspaces` was the last one — `self-hosted-macos` plus `signing-host`, installed at `~/.local/share/actions-runner-workspaces` — and it was deregistered and removed from the host on 2026-08-13. `.github/actionlint.yaml` now allows no self-hosted label at all, so a `runs-on` reaching for one fails lint rather than queueing against hardware that is gone.

It came out before the condition it was being held for: hosted notarization still has not run green, and the last successful notarization anywhere was self-hosted on 2026-07-11. So moving releases back is a re-provision, not a label flip — register a runner, add the label to `.github/actionlint.yaml`, drop it from `RETIRED_RUNNER_LABELS` in `scripts/audit-security-posture.py`, then change `runs-on`. The runbook covers all four: [docs/development/signing-runner-setup.md](./docs/development/signing-runner-setup.md).

### Focus stealing prevention

The app auto-detects CI (via the standard `CI` env var) and uses `.accessory` activation policy — no dock icon, no Cmd+Tab, no focus steal. Three activation modes:

| Mode | Activation Policy | Behavior |
|------|-------------------|----------|
| Normal launch | `.regular` + `activate()` | Dock + Cmd+Tab + foreground |
| `--no-activate` | `.regular`, skip `activate()` | Dock + Cmd+Tab, stays behind |
| CI (`CI=true`) | `.accessory` | Invisible |

If you write a script that launches the app headlessly, set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`:

```bash
WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 swift run WorkspaceManager
```

### CI visibility setup

A SwiftBar menu bar plugin shows live runner status so you know when CI is active on your machine. Nothing in this repo puts CI there any more, so this is for a host that has been re-provisioned — run it after the runner is registered, not before, since the hook installer writes into each runner's `.env` and has nothing to write to otherwise.

**One-time setup:**

```bash
# 1. Install SwiftBar
brew install --cask swiftbar

# 2. Configure SwiftBar to use a plugin folder (e.g. ~/swiftbar)
#    Open SwiftBar preferences and set the plugin folder

# 3. Install the menu bar plugin
./scripts/install-runner-ci-menubar.sh ~/swiftbar

# 4. Install runner activity hooks (writes to all runners' .env files)
./scripts/install-runner-hooks.sh

# 5. Restart runners to pick up hooks (wait for in-flight jobs to finish)
#    The install script prints restart commands for each runner
```

**What you'll see:**

- Menu bar shows `CI` with a status icon (gray checkmark = idle, orange hammer = running)
- Click to expand: per-runner status, recent activity log
- Hooks log every job start/end to `~/.local/share/runner-activity.log`

**CLI status check** (no SwiftBar needed):

```bash
./scripts/runners.py            # every runner on this machine
./scripts/runners.py --offline  # skip the GitHub API (~0.4s)
./scripts/runners.py --disk     # add per-runner disk usage
./scripts/runners.py --json     # machine-readable snapshot
```

`runners.py` discovers runner directories by glob and reconciles three sources
that drift apart silently — the local `.runner` config, launchd job state, and
GitHub's own runner list. A runner is healthy only when all three agree, so a
registration deleted server-side while launchd still lists the job shows up as
`dead` rather than merely quiet. Exit status is 1 when any runner is dead, which
makes it usable as a gate.

The recent-jobs block reports what each finished job actually did. The
completed-job hook cannot know that — job status reaches a runner only through
the API — so the hook records the run id and `runners.py` resolves the verdict
when it renders. Anything GitHub has not confirmed reads `? unknown` rather than
as a pass, and lines predating the run id stay that way permanently.

A concluded attempt never revises its verdict, so answers are kept in
`~/.local/share/runner-activity-outcomes.json` and only unseen lines cost an API
call — which is also what lets `--offline` show real outcomes for jobs already
looked up. Delete that file to re-fetch everything.

It supersedes `runner-status.sh`, which reads a hardcoded list of three runner
directories and never asks GitHub anything. On a machine with twelve runner
directories that meant nine were invisible, and a runner whose registration had
been deleted was indistinguishable from one that was merely offline.

### Runner scripts reference

| Script | Purpose |
|--------|---------|
| `runners.py` | Status of every runner: local config, launchd, and GitHub reconciled |
| `runner-status.sh` | Superseded by `runners.py`; hardcodes three runner dirs, no GitHub check |
| `runner-ci-menubar.5s.sh` | SwiftBar plugin (installed into plugin folder) |
| `install-runner-ci-menubar.sh` | Installs the SwiftBar plugin as a durable local copy |
| `runner-notify-start.sh` | Runner hook: logs job start to activity log |
| `runner-notify-complete.sh` | Runner hook: logs that a job ended, plus the run id to resolve its outcome against |
| `install-runner-hooks.sh` | Installs hooks on all runners (copies scripts, updates .env) |

Parked, revival intended (owner decision 2026-08-02): kept despite low day-to-day use while the primary CI lane is GitHub-hosted/Lume-backed — do not re-flag as dead code in future cleanup passes.

The Daytona remote-workspace surface (`Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift`, `scripts/daytona-sandbox-manager.py`, `web/src/lib/agent-runtime/daytona.ts` stub provider) is parked under the same 2026-08-02 owner decision — see `docs/daytona-vm.md`.

## Agent Self-Verification

A bundled [tart-gui-automation](.agents/skills/tart-gui-automation/) skill lets Claude Code (or any coding agent) build and launch the app in an ephemeral Tart macOS VM, capture screenshots, and verify UI behavior without touching the host. See `Sources/AGENTS.md` § "Dev Verification Practice" for the workflow.

Requires [Tart](https://github.com/cirruslabs/tart) and a macOS guest image (`macos-tahoe-xcode`).

## Release and Signing

- Release process: [RELEASING.md](./RELEASING.md)
- Ghostty integration details: `docs/development/libghostty-integration.md`
