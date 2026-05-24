---
topic: sparkle-appcast-release-notes
relates_to: after:sparkle-autoupdate-plan
priority: 2
description: Capture release runbook and appcast script hardening follow-ups from PR #497 review.
completed: 2026-05-24
---

# Sparkle Appcast Release Notes Follow-ups

## Outcome

Implemented the release-note precondition in `RELEASING.md`, kept the Sparkle autoupdate plan aligned, and documented the trusted release-workflow boundary around appcast URL interpolation in `scripts/generate-sparkle-appcast.sh`.

Verification:
- `bash -n scripts/generate-sparkle-appcast.sh`
- `swift test --filter SparkleAppcastScript`
- `rg -n "CHANGELOG.md|generate-sparkle-appcast|fullReleaseNotesLink" RELEASING.md backlog/sparkle-autoupdate-plan.md scripts/generate-sparkle-appcast.sh`

## Problem Statement

PR #497 made generated Sparkle appcasts depend on a version-matched `CHANGELOG.md` entry. That is the right release artifact contract, but it creates a new hard release precondition that should be easy for future release operators and agents to see before the protected release workflow reaches appcast signing.

The PR review also called out a safe-but-implicit script assumption: `scripts/generate-sparkle-appcast.sh` interpolates `$REPO` and `$TAG` into XML and release URLs directly. In the current release workflow those values come from controlled repository metadata and a validated release tag, so this is not a blocker. If the script is reused more broadly, that assumption should either be documented in code or hardened.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Release precondition | Document `CHANGELOG.md` entry before appcast generation | Missing notes now fail the release before signing, so the runbook should state the requirement explicitly. |
| Script reuse assumption | Start with a local comment, harden only if inputs become less controlled | The current workflow controls `GITHUB_REPOSITORY` and tag inputs; validation work is only needed if the script becomes a general-purpose appcast generator. |

## Implementation Phases

### Phase 1: Release Runbook Note

**Files to modify:**
- `RELEASING.md` - add the appcast release-notes precondition near the `prepare-release.sh` / changelog flow.
- `backlog/sparkle-autoupdate-plan.md` - add the same note under Release Integration so the Sparkle update plan stays current.

**Acceptance criteria:**
- [x] Release docs state that `CHANGELOG.md` must contain `## [CFBundleShortVersionString] - <date>` before `scripts/generate-sparkle-appcast.sh` runs.
- [x] Docs mention that the generated appcast embeds that section in `<description>` and fails if it is missing or empty.

### Phase 2: Appcast Script Assumption Comment

**Files to modify:**
- `scripts/generate-sparkle-appcast.sh` - add a short comment near `DOWNLOAD_URL`, `RELEASE_URL`, and `CHANGELOG_URL` explaining that `$REPO` comes from `GITHUB_REPOSITORY` and `$TAG` is validated by release preparation before the release workflow runs.

**Acceptance criteria:**
- [x] The comment makes the trust boundary explicit without adding noisy escaping code for the current release-only use case.
- [x] If future work allows arbitrary `--repo` or `--tag` values from untrusted callers, the follow-up either constrains those values or escapes them before XML interpolation.

## Verification Commands

```bash
bash -n scripts/generate-sparkle-appcast.sh
swift test --filter SparkleAppcastScript
rg -n "CHANGELOG.md|generate-sparkle-appcast|fullReleaseNotesLink" RELEASING.md backlog/sparkle-autoupdate-plan.md scripts/generate-sparkle-appcast.sh
```

## Rollback Plan

Remove the added documentation/comment-only changes. Do not weaken the appcast generator guard introduced in PR #497 unless the release process gets a replacement source for signed release notes.

## References

- PR #497: `release: embed changelog notes in Sparkle appcast`
- `scripts/generate-sparkle-appcast.sh`
- `Tests/WorkspaceManagerAppTests/SparkleAppcastScriptTests.swift`
- `backlog/sparkle-autoupdate-plan.md`
