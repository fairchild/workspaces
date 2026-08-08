# UI-state goldens

One JSON document per fixture scenario, pinning the structural UI state
(`AutomationUIStateSnapshot`) a fixture-mode launch renders — selection, banner
presence, sidebar rows with status tokens, the attention pill, terminal topology.
The evidence lane diffs the live `GET /v1/ui-state` read against the matching
golden and fails on mismatch, so a regression that is visible in a screenshot is
also detectable by machine.

Document shape:

```json
{
  "scenario": "<fixture scenario id>",
  "ignore": ["dot.paths.pruned.before.compare"],
  "settle": { "timeoutSeconds": 20, "pollSeconds": 1 },
  "state": { ... AutomationUIStateSnapshot JSON ... }
}
```

- `state` holds only run-stable fields by schema contract; volatile data (SwiftData
  ids, shell-controlled tab titles) rides the wire in a sibling `volatile` subtree
  that is never compared.
- `ignore` is the escape hatch for fields that later prove machine-varying; arrays
  are traversed element-wise (`sidebar.workspaces.name` strips every row's name).
- `settle` is optional, and belongs to goldens whose chrome cannot exist at first
  paint. `orphan-banner` is the case: the orphan scan runs in the deferred startup
  pass (`performDeferredStartupWorkspaceStatusSync`, ~2s after the first render),
  well after the capture lane's readiness signal, so a single-shot verify would race
  it. With a settle declared, `verify` re-fetches on `pollSeconds` until the state
  matches or `timeoutSeconds` elapses, then fails naming the bound and the final
  mismatch. Scenarios without deferred chrome declare none and stay single-shot.
- Comparison semantics are canonical in `UIStateGolden.swift`
  (`Sources/WorkspaceManagerCore/Services/Automation/`), unit-tested in
  `Tests/WorkspaceManagerTests/AutomationUIStateTests.swift`. `ignore` and `settle`
  are authored decisions, so `update` carries them forward rather than regenerating
  them.

A golden mirrors the wire: `update` writes `state` exactly as the response delivered
it, key order included (the automation API already emits sorted keys), so an update
against an unchanged app rewrites the same bytes and shows no diff.
`scripts/tests/test_ui_state_golden.py` pins that against the shipped files.

Updating a golden is always explicit — a mismatch never regenerates anything:

```bash
scripts/ui-state-golden.sh update --scenario clean   # against a running fixture app
swift test --filter UIStateGolden                    # then re-verify offline
```
