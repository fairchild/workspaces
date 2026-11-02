# Remote (claude.ai) Session Conventions

How to set up and work in the cloud environment that Claude Code cloud sessions
run in. The environment itself lives in claude.ai and agents can't edit it, so
this page is its record: a change lands here by pull request, and the owner
applies anything that isn't fetched from `main`. Tracking issue:
[#734](https://github.com/fairchild/workspaces/issues/734).

**Status, 2026-11-02:** the scripts below ran end to end in a clean Ubuntu 24.04
x86_64 container, emulated and without the network proxy. They have not yet run in
a live environment. To confirm one works, start a session and read what the
SessionStart hook reports: it names every setup step that failed.

## What a cloud session can do

The VM is Ubuntu on x86_64, so the macOS app can't build there.

| Work | In a cloud session |
|---|---|
| `web-next/` and `web/`: install, typecheck, lint, unit tests | Yes |
| Playwright e2e | Yes, with the browser setup installs |
| `mise run lint` (`swift-format`) | Yes. Its `format` output matched macOS byte for byte across `Sources/` and `Tests/` |
| Edit Swift, scripts and docs | Yes, and CI checks the result |
| `swift build`, `swift test` | No. Push the branch and read the macOS CI run |
| App UI evidence (`scripts/evidence.sh --fixture`) | No. Needs macOS |
| Lume, Tart, release and signing lanes | No |

`GhosttyKit` and the app target are macOS-only, and `WorkspaceManagerCore` itself
imports `Darwin`, `os.log` and `Combine`, so no target compiles on Linux today.

## Create the environment

Open the environment selector at [claude.ai/code](https://claude.ai/code),
choose **New environment**, and fill in the dialog:

- **Name:** `workspaces`
- **Network access:** Custom, with **Also include default list of common package
  managers** ticked, and these allowed domains:

  ```text
  pkg-containers.githubusercontent.com
  cdn.playwright.dev
  playwright.download.prss.microsoft.com
  ```

  The first serves `ghcr.io` blobs, which is where `swift-format` comes from; the
  other two serve Playwright's browsers.

- **Environment variables:**

  ```text
  PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
  EVIDENCE_UPLOAD_TOKEN=proxy-injected
  BASH_DEFAULT_TIMEOUT_MS=600000
  BASH_MAX_TIMEOUT_MS=1800000
  ```

- **Setup script:**

  ```bash
  #!/bin/bash
  # workspaces cloud environment, rev 1. Editing any line of this script rebuilds the cache.
  curl -fsSL https://raw.githubusercontent.com/fairchild/workspaces/main/scripts/cloud-environment.sh | bash
  curl -fsSL https://raw.githubusercontent.com/fairchild/dotclaude/main/scripts/cloud-bootstrap.sh | bash
  exit 0
  ```

  The second `curl` carries the owner's personal Claude config. Leave it out of
  anyone else's environment.

- **Network secret** (save the environment first, then add it): Bearer, allowed
  website `evidence.cloudcompute.com`, value `EVIDENCE_UPLOAD_TOKEN` from a local
  checkout's `.env` (GitHub secrets can't be read back). The proxy attaches it to
  uploads, so the real token never enters the VM; the placeholder variable above
  only gets past the `scripts/evidence.sh` token check.

Start sessions on this repository alone, outside a Claude Project. A session with
a second repository attached, or a thread in a Project, skips this repository's
`.claude/settings.json`, and with it the SessionStart hook.

## How it fits together

| Piece | Where it lives | When it runs |
|---|---|---|
| Tools: mise, prek, swift-format, Playwright browsers, pnpm store | [`scripts/cloud-environment.sh`](../../scripts/cloud-environment.sh) | Setup, then cached |
| Personal config: `CLAUDE.md`, skills, agents, deny rules | `scripts/cloud-bootstrap.sh` in `fairchild/dotclaude` | Setup, then cached |
| Project state: `pnpm install`, git hooks, the session's status report | [`scripts/cloud-session-start.sh`](../../scripts/cloud-session-start.sh) | Every start and resume |

The setup script is a stub that fetches from `main`, so a merged change needs no
paste. It reaches sessions when the cache next rebuilds: about every seven days,
or at once if you edit the stub, which is what its `rev` line is for.

Three constraints shaped this split:

- **`git` is unreliable during setup.** `git fetch` on the clone has been seen to
  fail there while the same command worked in the session. The likely cause is that
  session credentials arrive later: the docs say the agent proxy connects after
  setup, and the failure itself wasn't recorded. Public release downloads have
  worked during setup, so setup fetches over plain HTTPS and never uses `git`.
- **Setup exits 0 or the session fails to start,** so nothing in it may fail
  loudly. Each step records its outcome in `/var/log/workspaces-cloud-setup/`,
  and the hook reads that back into the session.
- **Past about five minutes, nothing is cached.** Steps run in parallel, each under
  a time limit.

## Working in a session

- **`gh pr` and `gh issue` fail** because the GitHub proxy blocks GraphQL. Use the
  built-in GitHub tools, or `gh api repos/fairchild/workspaces/...` for REST.
- **`GH_TOKEN` reads `proxy-injected`.** The proxy substitutes the real credential,
  so a script that reads the value directly gets the placeholder.
- **Don't run `playwright install`.** If the hook reports the pinned browser
  missing, a setup step failed or the cache predates a Playwright bump: edit the
  setup script's `rev` to rebuild.
- **`mise run` won't install `[tools]`.** Setup turns that off, because `zig` only
  builds `GhosttyKit`, needs `ziglang.org`, and would rewrite `mise.lock`.
- **`codex` isn't installed,** so `codex-review-loop` runs from a local session.

## Evidence

With the network secret in place, `scripts/evidence.sh --pr <N> --name <slug> --file
<path> --no-capture` uploads from a session.

Without it, a green CI run on the exact branch and commit is acceptable hosted
evidence: cite it in the PR's Evidence section as
`[Web CI passed on this branch](<run url>)` and say the token was unavailable.
Limits of that convention:

- **UI screenshots** have no CI equivalent. Capture them with Playwright from
  the exact commit, deliver them to the reviewer through the session (they render
  inline), and describe each shot in the PR body so the Vercel preview can be
  checked against them. State that R2 upload was blocked. Do not commit
  screenshots (`output/` policy) and do not paste local paths as evidence links.
- **Suites CI doesn't run** (the Playwright `full` project) need explicit
  runs — say exactly what ran where. Two independent green runs (author +
  gate) is the bar this repo has used.

## Session practices that earn their keep

- **File human-lane blockers as issues the moment you hit them** (labels
  `ops`/`human`), not at reflection time. On 2026-07-02 the evidence-token gap
  was confirmed in the first hour but filed six hours later — every agent in
  between paid the same workaround. An early issue gives the owner a chance to
  fix the environment mid-session.
- **Wait on PR checks with `scripts/pr-wait.sh <sha>`** (blocks until check
  runs are terminal; exits 0 only if all latest runs are green/skipped). Webhook subscription + a per-SHA wait beats a
  recurring cron for PR babysitting — and beats hand-rolled poll loops, one of
  which shipped with an early-exit bug before this script existed.
- **Capture full command output to a file first, filter second.** A flaky test's
  identity was lost in this repo once because grep pipelines ate the failure
  name before anyone saved raw output. `cmd > log 2>&1` then grep the log.
- **Pre-check merges with `git merge-tree --write-tree`** (the new-style form).
  The legacy three-argument `merge-tree` under-reports conflicts and produced a
  false "clean" on a real LEDGER.md conflict (PR #732).
- **`web/tests/LEDGER.md` is a designed-in merge hotspot** — parallel PRs that
  both add behavior rows will conflict there. The conflicts are additive (keep
  both blocks); either serialize the PRs or budget a trivial resolution.
