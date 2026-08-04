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

## Repo variables (`repo-variables.json`)

`repo-variables.json` lists every `FACTORY_*_ENABLED` kill-switch variable a
workflow under `.github/workflows/` gates on (name → which workflow it
gates). A workflow can reference `vars.FACTORY_FOO_ENABLED` in an `if:` and
ship green with the lane 100% dead if nobody ever runs `gh variable set
FACTORY_FOO_ENABLED --body true` — that's what happened to
`factory-evidence-verify.yml` (#1149).

Two checks close that gap, both running unattended in CI:

```bash
uv run --script scripts/tests/test_factory_workflows.py   # every vars.FACTORY_*_ENABLED reference has a manifest entry
mise run repo-variables-check                              # every manifest entry exists as a live repo variable
```

The first reads only local files (workflow YAML + the manifest) and runs in
`ci-agents.yml`'s `contents: read` job on any workflow-file change. The
second needs live variable values; `.github/workflows/repo-variables-drift.yml`
supplies them via `${{ toJSON(vars) }}` — the `vars` context is populated by
Actions for every job, so unlike the rulesets read above (which also works
off the default token) *and* unlike `gh variable list`'s REST endpoint (which
needs a PAT — Actions variables aren't among `GITHUB_TOKEN`'s permission
scopes), no elevated token is needed here either. That workflow runs on a
daily schedule plus PRs touching the manifest or any workflow file. Running
`mise run repo-variables-check` locally (no `REPO_VARS_JSON` set) falls back
to `gh variable list`, so it still needs a `gh` authenticated with
variable-read access there.

Adding a new `FACTORY_*_ENABLED` gate: add its name to `repo-variables.json`,
then `gh variable set <name> --body true` before merging (or `--body false`
to ship it dark on purpose).
