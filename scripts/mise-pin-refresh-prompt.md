# Weekly mise-pin-refresh routine

You are running as the weekly mise-pin-refresh routine for the
fairchild/workspaces repo. Keep the sandbox mise pin fresh while maintaining
at most ONE open bump PR, on the fixed branch `auto/mise-pin-refresh`.

1. Pre-flight: from the latest `main`, run
   `uv run --script scripts/mise-pin-refresh.py` (plain
   `python3 scripts/mise-pin-refresh.py` also works — stdlib only).
   Exit 0 / "pin ... is current" → nothing to do, stop here.
2. Create or reset the branch `auto/mise-pin-refresh` onto the latest
   `origin/main` (never work on `main` directly), then run
   `uv run --script scripts/mise-pin-refresh.py --apply`
   (rewrites the pin version + linux-x64 sha256 across the three pin sites,
   sha taken from upstream SHASUMS256.txt). Then run the guard suite:
   `uv run --script scripts/tests/test_security_hardening.py` — must pass.
3. Commit exactly the three changed files with message
   `chore(security): bump sandbox mise pin to <new version> (weekly refresh)`.
   Force-push: `git push -f origin auto/mise-pin-refresh`.
4. If an open PR with head branch auto/mise-pin-refresh already exists
   (`gh pr list --state open --head auto/mise-pin-refresh`), the push updated
   it — add a comment noting the new version and stop. Otherwise create the
   PR, filling the repo PR template completely: every Mergeability field
   (Surface: agent-runtime / infra; user-facing: none, sandboxes install the
   new mise; non-happy paths: install fails closed on checksum mismatch, sha
   sourced from upstream SHASUMS256.txt; release/ops preconditions: none;
   residual risk: mise regressions surface at next sandbox creation,
   rollback = revert). Under Evidence check "Not a testable change" and state
   that this PR's own Mise Security lane re-validates the pin against
   upstream SHASUMS256.txt. Blockers: None. Apply the label
   author:mise-pin-refresh (create it first with
   `gh label create author:mise-pin-refresh --color 5319e7 2>/dev/null || true`).
5. Touch nothing beyond the three pin sites. On any surprise (apply fails,
   tests fail, upstream release looks wrong), do NOT improvise a fix — open
   an issue titled "mise-pin-refresh needs attention" describing what you
   saw, and stop.
