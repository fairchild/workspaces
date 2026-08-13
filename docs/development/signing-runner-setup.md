# Signing Runner Setup

> **The `Release` workflow no longer uses this lane.** Signing and notarization
> run on hosted `macos-15`, taking every credential from repository secrets. This
> runbook is retained as the revert path: hosted notarization has not yet run
> green, and until it does, `blue-workspaces` stays registered with `signing-host`
> so releases can be moved back with a one-line `runs-on` change. Once a hosted
> release notarizes, the runner is deregistered and this document goes with it.

Use this runbook to provision or relabel the dedicated `[self-hosted, signing-host]` lane.

## Why it existed

Targeting `[self-hosted, signing-host]` rather than a generic self-hosted runner kept signing and notarization isolated from routine desktop CI and Tart UI automation.

`signing-host` is a mutable GitHub runner label, not repo state. A workflow that targets it will queue indefinitely if no online runner advertises it, even when other self-hosted runners are healthy.

Runner readiness is separate from protected environment approval. The release
workflow may wait on the GitHub `release` environment before checkout, signing
material import, or notarization begins. Approve that environment only after the
release tag, version metadata, and changelog are ready to publish.

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

If the run is waiting on the protected `release` environment, approve or reject
that gate in GitHub Actions before expecting the runner assignment to proceed.

If repository release credentials are intentionally unavailable in the current environment, stop after the job is claimed by the correct runner.

## 5. Move or remove the label

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
