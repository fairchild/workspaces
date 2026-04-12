# Evidence Guide

Evidence is a merge gate for all PRs. Upload test results or screenshots before creating a PR.

## Quick start

```bash
# Capture screenshot + upload in one step
./scripts/evidence.sh --pr <number> --name <slug>

# Upload an existing file
./scripts/evidence.sh --pr <number> --name <slug> --file /tmp/screenshot.png

# Via mise
mise run evidence -- --pr <number> --name <slug>
```

The script prints a markdown image link you can paste directly into the PR body.

## Setup

Add `EVIDENCE_UPLOAD_TOKEN` to your `.env` (gitignored):

```
EVIDENCE_UPLOAD_TOKEN=<value>
```

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
| `--name <slug>` | Yes | Filename slug (e.g., `test-results`, `before-fix`) |
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
| Swift UI | `swift test` summary screenshot | Screenshot of running app |
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
| `EVIDENCE_UPLOAD_TOKEN not set` | Token missing from `.env` | Add it — see [Setup](#setup) |
| `401 unauthorized` on upload | Token mismatch | Rotate token across Worker + GitHub + `.env` |
| Auth redirect on localhost | Web middleware requires session | Use `DEV_BYPASS_AUTH=1 pnpm dev` |
| `screencapture` fails | No display (headless/SSH) | Use `--file` with an existing screenshot |
| URL returns 404 | Upload didn't complete | Re-run `evidence.sh`, check network |

## Architecture

Screenshots flow through: `evidence.sh` → `upload-evidence.py` (PUT with bearer token) → Cloudflare Worker (`infra/cloudflare-evidence-store/`) → R2 bucket (`evidence-screenshots`) → public URL at `https://evidence.cloudcompute.com/`.

For infrastructure details (Worker deployment, R2 bucket config, runner setup), see [lume-runner-setup.md § Evidence store](lume-runner-setup.md#evidence-store-r2).
