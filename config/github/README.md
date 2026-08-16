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

## Environments (`environments/`)

`environments/<name>.json` holds one deployment environment each: its protection
rules (`reviewers`, `wait_timer`, `prevent_self_review`) and its deployment
branch policy, including the exact list of allowed branches and tags. Same
workflow as rulesets — edit the JSON in a PR, `apply` after merge, and the drift
run catches a change made in the UI. Add one with `{"name": "<live-name>"}` and
`snapshot`.

These gate the release path, so drift here is worth catching: `release` requires
a human approval and admits only `main` plus `v*` / `workspaces-v*` tags, and
`xcode-cloud-logs` admits only `main` and `ci/xcode-cloud-logs`. Weakening either
in the UI is invisible without this check.

Two deliberate choices:

- **Reviewers are stored by login, not id.** Numeric ids make diffs unreadable;
  `apply` resolves the login back to an id. `apply` always sends the reviewer
  list, because the environments `PUT` *clears* reviewers when the field is
  omitted — which would silently remove the approval gate on `release`.
- **Secret names live in `scripts/audit-security-posture.py`, not here.** That
  script already checks which names exist in which scope, and duplicating the
  list would create the second source of truth this directory exists to prevent.
  Secret *values* appear in neither. The two tools are complementary: this one
  owns protection rules, that one owns secret placement.

## App manifests (`apps/`)

`apps/<slug>.manifest.json` holds the [GitHub App manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)
used to create that App via the manifest flow (`POST /settings/apps/new` with
the file's contents as the `manifest` form field) — creating and installing
the App itself is still a manual, owner-only click; the file just keeps the
desired permissions/description as reviewable, versioned config instead of
tribal knowledge. `docs/development/github-app-identities.md` is the
canonical table of which Apps exist, their bot login, and required
permissions; a manifest here should match that doc's row for the same App.
Not every existing App has a manifest file checked in yet — `apps/` started
with `workspaces-factory` (issue #1180); backfilling the others is optional
cleanup, not required. When an App's logo is re-uploaded in the GitHub UI,
update the committed copy at `apps/<slug>-logo.png` (e.g.
`apps/workspaces-factory-logo.png`) in the same change, so the config-as-code
copy never drifts from what's actually live.

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
