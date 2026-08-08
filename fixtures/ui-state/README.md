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
  "state": { ... AutomationUIStateSnapshot JSON ... }
}
```

- `state` holds only run-stable fields by schema contract; volatile data (SwiftData
  ids, shell-controlled tab titles) rides the wire in a sibling `volatile` subtree
  that is never compared.
- `ignore` is the escape hatch for fields that later prove machine-varying; arrays
  are traversed element-wise (`sidebar.workspaces.name` strips every row's name).
- Comparison semantics are canonical in `UIStateGolden.swift`
  (`Sources/WorkspaceManagerCore/Services/Automation/`), unit-tested in
  `Tests/WorkspaceManagerTests/AutomationUIStateTests.swift`.

Updating a golden is always explicit — a mismatch never regenerates anything:

```bash
scripts/ui-state-golden.sh update --scenario clean   # against a running fixture app
swift test --filter UIStateGolden                    # then re-verify offline
```
