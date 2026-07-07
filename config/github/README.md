# GitHub repo settings as code

Desired state for this repo's GitHub-side settings. `rulesets/<name>.json`
holds one repository ruleset each (the writable fields of the
[rulesets API](https://docs.github.com/en/rest/repos/rules) object), matched
to the live ruleset by its `name` field. All `main` merge gates — required
status checks, PR rules, linear history, deletion/force-push protection —
live in the `main-merge` ruleset; classic branch protection is not used.

```bash
uv run --script scripts/github-settings.py check      # diff live vs. files, exit 1 on drift
uv run --script scripts/github-settings.py apply      # push files to GitHub (needs repo admin)
uv run --script scripts/github-settings.py snapshot   # overwrite files from live state
```

Changing a setting is a PR that edits the JSON, then `apply` after merge.
`.github/workflows/repo-settings-drift.yml` runs `check` on a schedule and on
PRs touching these files, so a settings change made in the GitHub UI without a
matching commit here shows up as a failing drift run. Reads work with the
default Actions token (rulesets are visible to anyone with read access);
`apply` needs an admin-authenticated `gh`, so it stays a deliberate local act.

To manage an additional ruleset, create `rulesets/<name>.json` containing
`{"name": "<live-name>"}` and run `snapshot`.
