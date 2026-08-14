# Signing Runner Setup

> **The `Release` workflow no longer uses this lane, and the lane no longer
> exists.** Signing and notarization run on hosted `macos-15`, taking every
> credential from repository secrets. `blue-workspaces` — the last runner
> carrying `signing-host` — was deregistered and removed from the host on
> 2026-08-13, before hosted notarization had proven itself green. This runbook is
> retained as the revert path, and that path is now a re-provision from nothing
> rather than a one-line `runs-on` change. Retire the document once a hosted
> release notarizes.

Use this runbook to stand the `[self-hosted, signing-host]` lane back up. Four
things have to change together — a runner, the lint allowlist, the audit's
retired set, and `runs-on` — and the release stays hosted until all four land.

## Why it existed

Targeting `[self-hosted, signing-host]` rather than a generic self-hosted runner kept signing and notarization isolated from routine desktop CI and Tart UI automation.

`signing-host` is a mutable GitHub runner label. Whether a runner advertises it is not repo state and cannot be read from the tree, and a workflow targeting a label nothing advertises queues indefinitely rather than failing — which is why `.github/actionlint.yaml` and `RETIRED_RUNNER_LABELS` now mirror the label's absence in the repo, so the mistake is caught at lint time instead of at dispatch.

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

As of 2026-08-13 this returns nothing — the repo has no registered runners. If
you see one, someone has already started; find out who before continuing.

## 2. Register a runner and give it the label

Nothing to relabel, so start from a fresh install. `scripts/runner.sh` does the
download, registration, and launchd wiring; its `RUNNER_LABELS` default is a
generic set, so name the lane explicitly:

```bash
RUNNER_LABELS=self-hosted-macos,signing-host \
RUNNER_NAME=blue-workspaces \
  ./scripts/runner.sh setup

./scripts/runner.sh service-install
./scripts/runner.sh service-start
```

`RUNNER_DIR` defaults to `~/.local/share/actions-runner-workspaces` — where the
removed runner lived, and where `install-runner-hooks.sh` looks. Keep it unless
you have a reason not to.

Notes:

- Keep the workflow contract explicit. Do not relax `.github/workflows/release.yml` back to bare `self-hosted`.
- Prefer a dedicated machine over an interactive desktop. The removed runner shared a laptop, which is why each job needed an isolated `HOME` to keep it from writing into the owner's `~/.gitconfig`.
- To label a runner that already exists, `gh api --method POST repos/fairchild/workspaces/actions/runners/<id>/labels --raw-field 'labels[]=signing-host'`.

## 3. Verify the label is live

```bash
gh api repos/fairchild/workspaces/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Confirm at least one online runner now includes `signing-host`.

## 4. Re-admit the lane in the repo, then point the release at it

Steps 1–3 make the runner available; they do not route anything to it. As shipped,
`build-sign-notarize-release` in `.github/workflows/release.yml` is `runs-on: macos-15`,
so dispatching `Release` now will not touch this runner no matter how healthy it is.

Three repo edits do that, and the first two gate the third — skip either and a
deliberate revert lands as a red PR:

1. `.github/actionlint.yaml` — add `signing-host` under `self-hosted-runner.labels`. The list is empty, so lint rejects every self-hosted label until you do.
2. `scripts/audit-security-posture.py` — remove `signing-host` from `RETIRED_RUNNER_LABELS`. It is listed as retired because nothing carries it; once a runner does, that stops being true.
3. `.github/workflows/release.yml`:

   ```yaml
     build-sign-notarize-release:
       runs-on: [self-hosted, signing-host]
   ```

Land all three in one PR that says which hosted signing or notarization failure
prompted it. The audit's "every release job runs on a hosted image" check fails
on the third edit by design — that failure is the record of the decision, so
explain it rather than silencing it.

## 5. Verify release scheduling

With the revert merged, dispatch or observe a `Release` run and confirm the job lands on the expected lane:

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
