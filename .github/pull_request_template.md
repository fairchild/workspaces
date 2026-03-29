## Summary

-

## Validation

- [ ] `swift build`
- [ ] `swift test`
- [ ] Other checks run:

## Performance

- [ ] Not a performance-sensitive change
- [ ] Baseline metrics were provided with the task
- [ ] Baseline metrics were gathered before changes
- [ ] Post-change metrics were gathered at the end of the work
- [ ] Before/after/delta is included below
- [ ] Any meaningful change, missing metric, target crossing, or non-comparable context is called out below

Performance evidence for performance-sensitive work should include:

- the metric source and exact commands used
- before and after values
- the workload and environment context
- a short note about the delta and whether the comparison is like-for-like

Performance evidence:

- 

Performance comparison notes:

- 

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
