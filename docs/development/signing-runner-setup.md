# Signing Runner Setup

Use this runbook to provision or relabel the dedicated `[self-hosted, signing-host]` lane required by the `Release` workflow.

## Default operating policy

- `signing-host` on the local interactive machine is opt-in only.
- Do not leave a local signing runner running in the background when no release is in progress.
- Start the runner for the release window, verify the release job is claimed, and stop it again when the work is finished.

See [self-hosted-runner-policy.md](./self-hosted-runner-policy.md) for the repo-wide default.

## Why this exists

The release workflow intentionally does not run on a generic self-hosted runner. It targets `[self-hosted, signing-host]` so signing and notarization stay isolated from routine desktop CI and Tart UI automation.

`signing-host` is a mutable GitHub runner label, not repo state. If no online runner advertises it, `Release` jobs will remain queued even when self-hosted runners are otherwise healthy.

## Prerequisites

- GitHub CLI authenticated with permission to inspect and update Actions runners for `fairchild/workspaces`
- A signing-capable macOS host with Xcode command line tools available
- The chosen host intentionally approved for release duties

## 1. Inspect the current runner inventory

```bash
gh api repos/fairchild/workspaces/actions/runners \
  --jq '.runners[] | {id, name, status, busy, labels: [.labels[].name]}'
```

Confirm there is at least one online runner you want to use for release work.

## 2. Assign the `signing-host` label

Pick the runner by name and add the label in GitHub:

```bash
RUNNER_NAME=blue-workspaces
RUNNER_ID="$(
  gh api repos/fairchild/workspaces/actions/runners \
    --jq ".runners[] | select(.name == \"${RUNNER_NAME}\") | .id"
)"

gh api --method POST \
  "repos/fairchild/workspaces/actions/runners/${RUNNER_ID}/labels" \
  --raw-field 'labels[]=signing-host'
```

Notes:

- Keep the workflow contract explicit. Do not relax `.github/workflows/release.yml` back to bare `self-hosted`.
- If a different machine should own releases, apply `signing-host` there instead of overloading the interactive desktop runner.

## 3. Verify the label is live

```bash
gh api repos/fairchild/workspaces/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Confirm at least one online runner now includes `signing-host`.

## 4. Verify release scheduling

Dispatch or observe a `Release` workflow run and confirm the job lands on the expected lane:

```bash
gh workflow run release.yml --ref main
gh run list --workflow Release --limit 1
gh api repos/fairchild/workspaces/actions/runs/<run-id>/jobs \
  --jq '.jobs[] | {name, status, labels, runner_name}'
```

The job should report labels including `self-hosted` and `signing-host`, and `runner_name` should resolve to the designated signing runner instead of remaining empty while queued.

If repository release credentials are intentionally unavailable in the current environment, stop after the job is claimed by the correct runner.

## 5. Stop the local signing runner after use

If the local host was only brought up for a release window, stop it when the release completes:

```bash
RUNNER_DIR="$HOME/.local/share/actions-runner-workspaces" \
  ./scripts/runner.sh service-stop
```

## 6. Move or remove the label

If release duties move to a different host:

```bash
gh api --method DELETE \
  repos/fairchild/workspaces/actions/runners/<runner-id>/labels/signing-host
```

Then add `signing-host` to the new designated runner and re-run the verification steps above.

## References

- [RELEASING.md](../../RELEASING.md)
- [.github/workflows/release.yml](../../.github/workflows/release.yml)
- [docs/development/tart-runner-setup.md](./tart-runner-setup.md)
