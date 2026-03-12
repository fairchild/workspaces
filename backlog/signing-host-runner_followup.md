---
topic: release-runner-provisioning
priority: 2
description: Provision and verify the dedicated signing-host self-hosted runner required by the Release workflow.
---

# Provision `signing-host` Release Runner

## Problem Statement

The release workflow now targets `[self-hosted, signing-host]` explicitly, which is the right safety model for signing and notarization. As of March 12, 2026, the `fairchild/workspaces` repo only shows two online runners via `gh api repos/fairchild/workspaces/actions/runners`: `blue-workspaces` (`self-hosted-macos`) and `workspaces-tart-ui` (`tart-ui`).

That means the workflow change is correct, but the operational lane it depends on has not been provisioned yet. Until a runner advertises the `signing-host` label, `Release` dispatches will remain queued or fail to start.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Release lane model | Keep `[self-hosted, signing-host]` | Signing and notarization should stay isolated from generic CI and Tart UI automation. |
| Scope of this follow-up | Provision a dedicated label, not a bare `self-hosted` fallback | Reintroducing bare `self-hosted` would undo the runner-lane safety change. |
| Validation source of truth | GitHub repo runner list plus a manual `Release` workflow dry-run check | Confirms both registration state and actual workflow scheduling behavior. |

## Implementation Phases

### Phase 1: Choose the host and label it

**Files to modify:**
- `RELEASING.md` - update any host-specific steps if the chosen signing host needs extra setup notes
- `scripts/runner.sh` - only if host provisioning reveals missing helper behavior for the signing lane

**Operational steps:**
- Decide whether an existing host should carry `signing-host` or whether a separate machine should be registered.
- Ensure the chosen host has the signing certificate, notarization credentials, and any required keychain setup already used by releases.
- Register or relabel the runner so GitHub shows `signing-host` in the custom labels list.

**Acceptance criteria:**
- [ ] `gh api repos/fairchild/workspaces/actions/runners` shows at least one online runner with `signing-host`
- [ ] The chosen host is intentionally scoped for signing/notarization work, not ad hoc desktop CI

### Phase 2: Validate release scheduling

**Operational steps:**
- Dispatch the `Release` workflow from `main` in a dry-run-safe way, or use a temporary test tag/release branch if the current workflow requires full execution.
- Confirm the job is claimed by the `signing-host` runner and does not queue indefinitely.
- If credentials are intentionally absent in the test environment, stop after runner selection is confirmed.

**Acceptance criteria:**
- [ ] `Release` schedules directly onto `[self-hosted, signing-host]`
- [ ] Documentation matches the real provisioning steps for that host

## Verification Commands

```bash
gh api repos/fairchild/workspaces/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'

gh workflow run release.yml --ref main
gh run list --workflow release.yml --limit 1
gh run view <run-id>
```

## Rollback Plan

If the chosen host should not be used for release duties, remove the `signing-host` custom label or unregister that runner from the repo. Do not change the workflow back to bare `self-hosted`; keep the explicit lane requirement and provision the correct host instead.

## References

- `.github/workflows/release.yml`
- `RELEASING.md`
- `AGENTS.md`
- `https://github.com/fairchild/workspaces/pull/71`
