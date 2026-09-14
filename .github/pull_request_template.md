<!--
Open with one paragraph, here, with no heading above it. Say why this pull
request exists and what it solves, then what changed and how big it is. Write it
for the reader deciding whether to care — ordinary prose, not four labelled
answers, not a bullet list. The title carries the same motive: after the
conventional-commit prefix, why the reader cares, what it solved, why this pull
request exists.

An example of the shape, not a template to fill in:

  Decisions on the steward's board wait hours for a click: on 2026-09-13 nine
  pull requests each waited eleven hours on one. This PR lets a decision be
  answered from a macOS notification, so a tap and a board click are the same
  event everywhere downstream. Off by default behind an experimental feature.
  12 files, +1496 -13.
-->

## What

-

## Mergeability

- Surface: desktop / web / agent-runtime / infra / docs
- User-facing behavior changed:
- Non-happy paths considered:
- Release/ops preconditions:
- Residual risk or follow-up:

## Validation

- [ ] `swift build`
- [ ] `swift test`
- [ ] Other checks run:

## Performance

- [ ] Not a performance-sensitive change
- [ ] Used canonical scenario(s) from `config/performance/contract.json`
- [ ] Before and after evidence came from a like-for-like workload and environment
- [ ] Any meaningful delta, missing metric, target crossing, or non-comparable context is called out below

For performance-sensitive work, capture canonical evidence with the scenario
that matches the changed surface:

```bash
# Debug-build UI/runtime branch deltas:
./scripts/prepare-perf-evidence.sh --scenario debug_no_activate

# Release, packaging, shell, or bundled Ghostty resource changes:
./scripts/build-release.sh --no-sign
./scripts/verify-installed-perf.sh build/WorkSpaces.app /tmp/workspaces-installed-perf-verify-<slug>
./scripts/perf-runner.sh --scenario installed_login_shell --app build/WorkSpaces.app
```

If this PR has the `performance-sensitive` label, fill all fields below. The `PR Perf Evidence` workflow enforces them.

Performance evidence:

- Scenario ID:
- Before Summary:
- After Summary:
- Delta Summary:

Performance comparison notes:

- Exact commands used:
- Workload / environment context:

## Evidence

- [ ] Not a testable change (docs-only, config)
- [ ] Tests named below: the command and the line it printed
- [ ] UI evidence attached (screenshot or recording from the exact commit under review)

<!-- Upload evidence: uv run scripts/upload-evidence.py <file> --repo workspaces --pr <number> --name <slug> -->
<!-- Tests: paste the command and the result line it printed -->

Evidence for all PRs must include:

- test results: the command used and its pass/fail summary line
- for UI changes: at least one screenshot or recording proving the result
- for API/backend changes: the named tests that ran, with the command
- anything uploaded: a hosted link (via upload-evidence.py), not a local file path

Evidence links:

-

## Blockers

- [ ] None
- [ ] Blocked on evidence

If blocked on evidence, explain why here. UI-affecting work needs explicit approval before shipping without visual proof.
