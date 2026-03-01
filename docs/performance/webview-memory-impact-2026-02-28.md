# WebView Memory + Size Impact (2026-02-28)

## Scope

This report captures measured impact from adding embedded WebKit support:

1. On-disk size impact vs pre-WebKit baseline commit.
2. Idle memory impact vs pre-WebKit baseline commit.
3. Incremental runtime memory when WebView is actively loaded.

## Baseline Comparison (pre-WebKit vs current)

Compared commits:

- pre-WebKit baseline: `32a451a58c8683563f7e2f86ed5f8631853330ea`
- current `codex/webview` working tree (HEAD commit: `898be635b29a139a63d1c55bb6ad548cf9015e46`)

### File size

- Release executable:
  - pre-WebKit: `14,853,104` bytes
  - current: `15,282,896` bytes
  - delta: `+429,792` bytes (`+2.89%`)
- Unsigned `.app` bundle (`du -sk build/WorkspaceManager.app`):
  - pre-WebKit: `17,976` KB
  - current: `18,396` KB
  - delta: `+420` KB (`+2.34%`)

### Idle RSS memory (release build, isolated data dir, 5 runs each)

- pre-WebKit mean RSS: `144,297.6` KB
- current mean RSS: `143,065.6` KB
- delta: `-1,232` KB (`-0.85%`)

Interpretation: no measurable idle-memory regression from linking WebKit when the web surface is not in use.

## Active WebView Incremental Memory

Date/time artifact:

- benchmark JSON: `output/tart-webview-benchmark/live/20260228-204558/benchmark.json`
- script: `scripts/tart-webview-memory-benchmark.sh`
- VM: `sequoia-base`
- binary: `release`
- runs: `5`

Method (per run):

1. Launch fixture app in idle mode and sample RSS.
2. Relaunch fixture app with `WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE=1` and sample RSS after WebKit helper processes appear.
3. Compute deltas.

Results (mean across 5 runs):

- app process RSS delta (`app_only.delta_kb.mean`): `+4,288.0` KB (`+4.19 MB`)
  - min/max: `+3,856` / `+4,672` KB
- WebKit helper process RSS delta (`webkit_processes.delta_kb.mean`): `+89,292.8` KB (`+87.20 MB`)
  - min/max: `+86,288` / `+100,768` KB
- approximate combined incremental footprint: `+93,580.8` KB (`+91.39 MB`)

Validation signals:

- `webkit_seen_count = 5/5` (WebKit helper process detected each run)
- `metric_seen_count = 0/5` in this release benchmark run; process-level detection was used as the load-complete signal.

## Commands Used

```bash
swift build
swift build -c release
./scripts/tart-webview-memory-benchmark.sh --base-vm sequoia-base --runs 5 --binary release
```

## Caveats

- RSS is inherently noisy; use trends and repeated runs, not single-run values.
- Web content complexity and network timing can change WebKit helper memory.
- Combined incremental value is approximated as:
  - `app_only.delta + webkit_processes.delta`
