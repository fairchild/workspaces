# Release approval after the candidate is ready

This retrospective records what v0.27.0 exposed and the accepted release
contract. The follow-up implements the repository workflow and migration
command; live activation requires merging it and applying that migration.

## Outcome and evidence

- [Metadata PR #1567](https://github.com/fairchild/workspaces/pull/1567) prepared
  version 0.27.0, build 35. Its reviewed tree matched merged commit
  `a2c6e4869072a49afabe4795a29e51f546c4e434`.
- [Merged-commit CI](https://github.com/fairchild/workspaces/actions/runs/34072559007)
  passed. Local release-note and metadata tests also passed, 22 tests in total.
- [Release #85](https://github.com/fairchild/workspaces/actions/runs/34072617930)
  failed its first attempt because preflight exhausted its 900-second polling
  budget while merged-commit CI was still running. The job occupied a hosted
  macOS runner from 01:19:45 to 01:36:06 UTC, about 16 minutes, without signing
  or publishing anything.
- The second attempt passed signing, notarization, publication, and published
  asset validation. It completed at 04:22:27 UTC on 2026-09-07.
- [v0.27.0](https://github.com/fairchild/workspaces/releases/tag/v0.27.0) was the
  latest stable release at the time of this retrospective. A direct download verified the DMG's stapled ticket,
  its manifest hash and source commit, and the signature and version served by
  `https://github.com/fairchild/workspaces/releases/latest/download/appcast.xml`.
  This does not claim an installed-app Sparkle upgrade was exercised.

## What cost extra work

The agent asked for chat confirmation even though the user had requested a
release. Automatic approval review also rejected an early rehearsal dispatch.
The right response is to make the authorized release concrete and ready for its
existing CI approval, not to insert a second routine approval in chat.

The agent then pushed the stable tag and exposed the approval page before
merged-commit CI was green. The user approved, preflight timed out, and GitHub
required another environment approval for the retry. Waiting for CI before
presenting the button would have avoided this failed attempt.

The pre-migration workflow had a deeper ordering problem. Its
`environment: release` gated `build-sign-notarize-release`, including its first CI preflight step.
Approval therefore precedes building, credential validation, signing,
notarization, and creation of a testable release candidate. It meant
permission to start preparing a signed release, not permission to publish a
finished one. A separate rehearsal adds another build and another approval.

The agent also reported unchanged polling states too often. CI should own
waiting and progression. User-visible updates should mark readiness, failures,
required action, and verified publication.

## Accepted release contract

The user's request to cut a release authorizes version selection, release
notes, the metadata PR, independent review, merge after required checks,
candidate preparation, and staging the publication approval. It does not
authorize skipping checks, absorbing unrelated PRs, or an agent clicking the
human publication approval.

```mermaid
flowchart LR
    A[Cut a release] --> B[Prepare and review metadata]
    B --> C[Merge and pass exact-commit CI]
    C --> D[Build, sign, notarize, test candidate]
    D --> E[Ready summary and candidate download]
    E --> F[One human publication approval]
    F --> G[Publish the same assets]
    G --> H[Verify public download and stable Sparkle feed]
```

1. **Prepare automatically.** Resolve the next version from stable release
   history and current main, review the notes in their Sparkle rendering,
   update version/build metadata, and complete the metadata PR through review
   and required checks. Pin the resulting merged commit. The generic release
   skill must route this repo through its repo-owned entry point rather than
   directly committing a changelog and publishing a bare GitHub release.
2. **Qualify before requesting approval.** Trigger candidate work only after
   successful CI on that exact commit. Use workflow dependencies or the
   completed-CI event; do not reserve a macOS runner merely to poll another run.
   Reject mismatched commits and failed or missing checks. Perform bundle,
   credential, notarization, version, notes, and benchmark-policy checks before
   the approval job becomes eligible.
3. **Build a real candidate once.** Sign and notarize the final DMG, generate its
   signed appcast and existing release manifest, and run appropriate packaged
   application smoke checks on that artifact. Retain the candidate as an
   immutable workflow artifact, with its artifact ID and digest, source SHA,
   version/build, asset hashes, and validation results bound together. Offer a
   clear authenticated download for optional manual testing. Candidate
   preparation must leave the public latest release and stable feed unchanged.
4. **Present one publication decision.** The summary identifies version/build,
   changes, exact source, completed checks, disclosed warnings, candidate
   download, and rollback release. Manual testing is optional and needs no
   separate confirmation. The publication environment requires the owner;
   signing credentials are unavailable to its publishing job. A changed or
   expired candidate cannot inherit an approval for different bytes.
5. **Promote without rebuilding.** After approval, verify artifact identity and
   all hashes again, reserve/verify the stable tag against the pinned source,
   upload and verify assets on a draft release, then publish it as latest.
   Serialize stable promotions and reject an attempt that would replace a
   newer stable version. Do not silently rebuild or replace approved assets.
   Bounded upload retries reuse the same bytes and release identity.
6. **Verify availability and finish.** Download the published versioned DMG and
   fetch the app's actual stable feed URL, following the latest-release redirect.
   Verify version/build, enclosure URL, signature, size, hashes, and
   notarization. Exercise an automated Sparkle upgrade from the previous
   version in an isolated supported test environment when available; otherwise
   report that boundary separately. Announce completion only after these
   checks, with the release and download links. The existing v0.27.0 workflow
   checks tag-specific assets after publication; the stable latest-feed fetch
   is an additional assertion it should own.

## The necessary credential-policy decision

A signed, notarized candidate cannot exist before approval while all signing
credentials remain behind that same approval. Candidate signing now uses a new
`release-candidate` environment on main. `release-publication` carries the human
gate and no secrets. The legacy `release` gate remains protected: review showed
that a completed historical main workflow could otherwise rerun and publish
without the new gate, even after all currently waiting runs were canceled.

The one-time setup checks the new publication policy and empty secret scope,
restricts candidate signing to main, and leaves candidate approval required
until its credentials are configured. Only that new environment becomes
automatic. Existing encrypted GitHub secret values cannot be read back or
copied by the API; setup loads the existing protected signing files into the
new environment. No old environment gate is removed.

Candidate qualification checks actual approving reviews over the full commit
range since the last stable release, rather than inferring review from a main
ref or a bypassable ruleset. A release-base marker detects main changes absent
from the notes, and a tooling comparison rejects old release code after a newer
hardening fix. Publication and downstream retries check the approved release
metadata and public asset bytes, including tester/latest semantics.

Performance measurements have a separate constraint:
[`perf-measurement-laptop-optin.md`](../decisions/perf-measurement-laptop-optin.md)
requires owner opt-in for laptop measurement sessions. v0.27.0 used the allowed
one-release-old benchmark evidence. The following release needs refreshed
evidence under the current policy. Candidate preparation must surface this
before the publication gate, and must not call stale or skipped benchmarks a
fresh performance pass. Full unattended preparation requires a separately
agreed way to supply those measurements.

## Encoding and implementation scope

The implementation replaces manual release branch/tag orchestration and CI
polling. It reuses the existing preparation, bundle, notarization, Sparkle,
manifest, and benchmark validators:

- `scripts/release.py` prepares or resumes a metadata PR and enables auto-merge
  after the repository's required review and checks.
- `release.yml` progresses from exact-source CI to candidate preparation,
  downloaded-installer validation, human-gated publication, and public checks.
- `scripts/release-candidate.py` binds identity and hashes, supplies the readiness
  summary, rejects expired/replaced candidates, and resumes only its own draft.
- `scripts/verify-release-candidate.sh` validates the actual candidate DMG and
  runs the packaged CLI without activating the desktop app. Full GUI/installed
  Sparkle upgrade remains an explicitly disclosed optional test.
- `scripts/release-environments.py` owns the fail-closed settings migration and
  the policy check reused by the existing security audit.
- `RELEASING.md` replaces rehearsal-then-rebuild instructions with candidate
  download, one approval, continuation, and recovery instructions.
- Existing script/workflow tests cover trust, ordering, substitution, expiry,
  legacy-gate protection, review proof, main movement, and resuming a partial draft without overwriting assets.

Live acceptance is complete when one ordinary request reaches one approval with a
downloadable, signed, validated candidate; accepting that approval publishes
the same bytes and verifies the stable Sparkle URL without further chat input.

## Platform references

- [GitHub deployment controls](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments)
  describe job-level environment approval and its relationship to secrets.
- [GitHub workflow artifacts](https://docs.github.com/en/enterprise-cloud%40latest/actions/tutorials/store-and-share-data)
  describe immutable artifacts and digest verification between jobs.
