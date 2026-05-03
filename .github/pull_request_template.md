## Summary

-

## Mergeability

- Surface: desktop / web / agent-runtime / infra / docs
- User-facing behavior changed:
- Non-happy paths considered:
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

For performance-sensitive work, capture canonical evidence with:

```bash
./scripts/prepare-perf-evidence.sh --scenario debug_no_activate
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
- [ ] Test evidence attached (Playwright report, test output, or equivalent)
- [ ] UI evidence attached (screenshot or recording from the exact commit under review)

<!-- Upload evidence: uv run scripts/upload-evidence.py <file> --repo workspaces --pr <number> --name <slug> -->
<!-- Web tests: cd web && pnpm test:evidence → screenshot playwright-report/index.html -->
<!-- Swift tests: swift test → screenshot output -->

Evidence for all PRs must include:

- test results: pass/fail summary with command used
- for UI changes: at least one screenshot or recording proving the result
- for API/backend changes: test report screenshot or output
- hosted links (via upload-evidence.py), not local file paths

Evidence links:

-

## Blockers

- [ ] None
- [ ] Blocked on evidence

If blocked on evidence, explain why here. Do not merge UI-affecting work without explicit approval to ship without visual proof.
