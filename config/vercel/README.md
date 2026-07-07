# Vercel env vars as code

Desired state for the two Vercel projects' production env vars: `spaces-web`
(dir `web/`) and `web-next` (dir `web-next/`), one manifest each. Two tiers:

- **`values`** — non-secret operational flags and debug-friendly config
  (`COMPUTE_PROVIDER`, `PR_REVIEWER_ENABLED`, IDs, URLs), checked by value.
  Membership is explicit curation, never inferred from readability — a
  secret with a misconfigured sensitive flag must not get snapshotted into
  the repo.
- **`present`** — secrets, checked by name only. Values never appear in-repo
  or in script output. Stored as sensitive-type vars in Vercel (unreadable
  after creation; recovery is rotation).

```bash
uv run --script scripts/vercel-settings.py check      # diff live vs. manifests, exit 1 on drift
uv run --script scripts/vercel-settings.py apply      # reconcile `values` keys (secrets untouched)
uv run --script scripts/vercel-settings.py snapshot   # refresh manifest values from live
```

Changing a flag is a PR that edits the manifest, then `apply` after merge —
and a **redeploy**: env changes only take effect on the next deployment.

Vars not listed in a manifest are ignored (Vercel injects `VERCEL_*`/`TURBO_*`
system vars; unmanaged vars are not drift). The script auto-links each project
dir when `.vercel/` is missing (fresh worktrees always are). Auth: logged-in
`vercel` CLI locally, `VERCEL_TOKEN` in CI. `VERCEL_BIN` overrides the CLI
command (e.g. `npx --yes vercel`).

`.github/workflows/vercel-settings-drift.yml` runs `check` daily; it soft-skips
until a `VERCEL_TOKEN` repo secret is configured.
