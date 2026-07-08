# Evidence Guide

Evidence is a merge gate for all PRs. Upload test results or screenshots before creating a PR.

> **Remote (claude.ai) sessions:** `EVIDENCE_UPLOAD_TOKEN` is not available in those containers. The sanctioned fallback — a green CI run link on the exact branch/commit as hosted evidence, plus session-delivered screenshots for UI changes — is documented in `remote-sessions.md`.

## Quick start

```bash
# App UI evidence — first-choice capture (launch fixture state, snapshot, upload)
./scripts/evidence.sh --pr <number> --fixture phase-1-release

# Capture the live desktop screenshot + upload in one step
./scripts/evidence.sh --pr <number> --name <slug>

# Upload an existing file
./scripts/evidence.sh --pr <number> --name <slug> --file /tmp/screenshot.png

# Via mise
mise run evidence -- --pr <number> --name <slug>
```

The script prints a markdown image link you can paste directly into the PR body.

## App evidence lane (first-choice UI capture)

For any evidence that shows the macOS app's UI, the app evidence lane is the
sanctioned first choice. One command launches the debug build in a named fixture
state with the Automation API and operator scope enabled, waits for readiness,
snapshots the main window through the operator-scope CLI, uploads through the
normal pipeline, and prints the markdown link — then stops the launched app:

```bash
./scripts/evidence.sh --pr <number> --fixture <scenario>
```

Named scenarios (`phase-1-release`, `m6-status-sliver`, `attention-only`,
`clean`, or `inline:<agent-states>`) come from
[`scripts/lib/fixture-scenarios.sh`](../../scripts/lib/fixture-scenarios.sh) and
match the release-screenshot catalog; the env grammar behind them lives in
[ui-fixture-mode.md](ui-fixture-mode.md). `--name` defaults to the scenario.

Why this is the default, and how it beats the older fallbacks:

- **Full composited fidelity, no focus steal.** The snapshot is
  `CGWindowListCreateImage` scoped to the app's own window — it captures the
  sidebar chrome *and* the GhosttyKit terminal surface in one PNG at true
  resolution, works with the app backgrounded on a shared desktop (no
  activation), and needs no Screen Recording TCC grant. See
  [automation-api.md § Window snapshot](automation-api.md#window-snapshot) and
  the [operator-scope ADR](../decisions/automation-operator-scope.md).
- **Deterministic state.** Fixture mode stages a known visual state in-memory, so
  the same command yields the same UI every run.

Failure behavior is fast and explicit (never a hang): a clear message when the
app can't launch, when operator scope is missing (no credential minted), when the
snapshot fails, or when `EVIDENCE_UPLOAD_TOKEN` is absent. Readiness waits are
bounded (`--timeout`, default 45s).

### Fallback hierarchy

Reach for a fallback only when the lane above cannot apply, in this order:

1. **App evidence lane** (`--fixture`) — default for all app-UI evidence.
2. **ImageRenderer test → PNG** — for a *single* SwiftUI view in a transient or
   hover-only state that fixture mode cannot stage as a full window. Renders one
   view, not the composited window.
3. **`qlmanage`-rendered test logs** — for non-UI changes where the evidence is
   test output, not pixels (render the log to PNG, then `--file --no-capture`).
4. **VM / `tart-ui` lane** — the full-fidelity fallback for the one case the
   in-process lane cannot cover: **a locked screen.** Every composited capture
   path (`CGWindowList` and ScreenCaptureKit) returns no pixels while the session
   is locked, so locked-screen evidence runs in a VM. Unlocked
   background/occluded windows capture fine with the lane above.

### Web UI evidence

The app lane is macOS-app only. Web dashboard evidence still uses
`mise run web:evidence` / Playwright report screenshots (see the web table
below and `web/docs/local-dev.md`).

## Setup

Add `EVIDENCE_UPLOAD_TOKEN` to your `.env` (gitignored):

```
EVIDENCE_UPLOAD_TOKEN=<value>
```

Fresh linked worktrees can symlink the checked-out secret file with:

```bash
./scripts/setup --env-only
```

`scripts/evidence.sh` also searches the canonical checkout and sibling worktrees for `.env` or `.env.local` before failing, so evidence upload should not be marked blocked just because the current worktree is missing its symlink.

The token value is stored in [GitHub repo secrets](https://github.com/fairchild/workspaces/settings/secrets/actions). To rotate it across all three locations:

```bash
TOKEN=$(openssl rand -hex 32)
cd infra/cloudflare-evidence-store && wrangler secret put EVIDENCE_UPLOAD_TOKEN <<< "$TOKEN"
gh secret set EVIDENCE_UPLOAD_TOKEN --repo fairchild/workspaces --body "$TOKEN"
# Then update .env manually
```

## Command reference

### `scripts/evidence.sh`

| Flag | Required | Description |
|------|----------|-------------|
| `--pr <number>` | Yes | PR number (used in R2 path) |
| `--name <slug>` | Yes* | Filename slug (e.g., `test-results`, `before-fix`). *In `--fixture` mode defaults to the scenario. |
| `--fixture <scenario>` | No | App evidence lane: launch a named fixture state, snapshot the main window via operator scope, upload. Known: `phase-1-release`, `m6-status-sliver`, `attention-only`, `clean`, `inline:<agent-states>`. |
| `--timeout <s>` | No | Readiness timeout for the fixture launch (default: 45) |
| `--keep-running` | No | Leave the launched app running after capture (debugging) |
| `--file <path>` | No | Use existing file instead of capturing screenshot |
| `--no-capture` | No | Skip `screencapture` (requires `--file`) |
| `--repo <name>` | No | Repository short name (default: `workspaces`) |

### `scripts/upload-evidence.py`

Lower-level upload client. Accepts png, jpg, gif, webp, svg. Called internally by `evidence.sh`.

```bash
uv run scripts/upload-evidence.py <file> --repo workspaces --pr <number> --name <slug>
```

## What counts as evidence

| Change type | Minimum evidence | Extras |
|-------------|-----------------|--------|
| Swift UI | `swift test` summary screenshot | Running-app screenshot via the [app evidence lane](#app-evidence-lane-first-choice-ui-capture) (`--fixture`) |
| Swift non-UI | `swift test` summary screenshot | — |
| Web | `pnpm test` output | Playwright report screenshot |
| API-only | Test output | — |
| Docs/config | Check "Not a testable change" in PR template | — |
| Performance | Before/after/delta metrics | Metric source and commands |

For web screenshots without auth, start the dev server with:

```bash
DEV_BYPASS_AUTH=1 pnpm dev
```

## How it's enforced

Three layers, from gentlest to strongest:

1. **PR template** (`.github/pull_request_template.md`) — Evidence checkboxes and links section prompt authors at creation time.
2. **CI reminder** (`.github/workflows/evidence-reminder.yml`) — Posts a comment with copy-paste commands on PRs missing evidence.
3. **Agent hook** (`.claude/settings.json`) — Fires a warning before `gh pr create` reminding agents to upload evidence first.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `EVIDENCE_UPLOAD_TOKEN not set` | Token missing from this checkout and no sibling checkout has it | Run `./scripts/setup --env-only`, or add it — see [Setup](#setup) |
| `401 unauthorized` on upload | Token mismatch | Rotate token across Worker + GitHub + `.env` |
| Auth redirect on localhost | Web middleware requires session | Use `DEV_BYPASS_AUTH=1 pnpm dev` |
| `screencapture` fails | No display (headless/SSH) | Use the `--fixture` app lane, or `--file` with an existing screenshot |
| `operator credential did not appear` | Fixture launch didn't enable operator scope, or the app failed to start | Check `.dev-data/logs/launch-diagnostics-*`; the lane sets `WORKSPACES_AUTOMATION_API=1` + `WORKSPACES_AUTOMATION_OPERATOR=1` for you |
| Snapshot `unsupported` on a locked screen | Composited capture returns no pixels while locked | Use the VM / `tart-ui` fallback lane |
| URL returns 404 | Upload didn't complete | Re-run `evidence.sh`, check network |

## Architecture

Screenshots flow through: `evidence.sh` → `upload-evidence.py` (PUT with bearer token) → Cloudflare Worker (`infra/cloudflare-evidence-store/`) → R2 bucket (`evidence-screenshots`) → public URL at `https://evidence.cloudcompute.com/`.

For infrastructure details (Worker deployment, R2 bucket config, runner setup), see [lume-runner-setup.md § Evidence store](lume-runner-setup.md#evidence-store-r2).
