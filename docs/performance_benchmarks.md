# Release performance benchmarks

`docs/performance_benchmarks.csv` is the committed record of how the app performed
at each release. The release workflow reads it as evidence rather than measuring
anything itself, which is what lets releases run on a hosted runner while perf
measurement stays where it can be trusted — a real Mac with a real display.

## Why the numbers are committed rather than measured at release time

Perf measurement moved to laptop-opt-in in
[#1280](https://github.com/fairchild/workspaces/pull/1280), recorded in
[`docs/decisions/perf-measurement-laptop-optin.md`](decisions/perf-measurement-laptop-optin.md).
The release job kept a copy of the old in-CI check that #1280 missed. It launched
the real app and waited for launch telemetry, which a CI session cannot produce,
and it blocked v0.24.0 with `missing installed perf metrics` after signing had
already succeeded.

Deleting that check outright would have traded one failure for a quieter one: no
perf signal at all, and nothing to notice its absence. That runs into the rule the
ADR states directly, from [#1238](https://github.com/fairchild/workspaces/issues/1238):

> **A skipped measurement must never be indistinguishable from a passing one.**

So the gate stayed and changed what it checks. It no longer asks *"is this build
fast?"* — it asks *"did anyone measure recently?"* — and it gets louder the longer
the answer is no.

## What the gate does

`scripts/check-perf-benchmarks.py` compares the newest `release_tag` in the CSV
against the `v*` tags that exist, and grades the gap:

| Releases since the last benchmarked one | Result |
|---|---|
| 0 — this release has a row | pass |
| 1 | **warn**, release proceeds |
| 2 or more | **fail**, release blocked |

Missing or empty CSV fails rather than passes, for the same reason: absent
evidence must not read as good news.

One release of slack is deliberate. Benchmarking is a manual, opt-in act on a
machine you have to be sitting at, so requiring it for every release would either
block releases or train you to fake the row. Two consecutive unmeasured releases
is a different thing — that is the point where a regression can hide behind a
number nobody has looked at since.

Run the gate yourself the way CI does:

```bash
./scripts/check-perf-benchmarks.py --tag v0.25.0
./scripts/check-perf-benchmarks.py --tag v0.25.0 --format github   # CI annotations
```

## Generating a row

Benchmarks come from the same runner the perf lane already uses. On the laptop,
against an installed build:

```bash
./scripts/build-release.sh
./scripts/perf-runner.sh --scenario installed_clean_shell
```

That writes a canonical `summary.json`. Append it to the launch-lane history and
read the medians back out:

```bash
./scripts/perf-history-record.py --summary <path-to-summary.json>
```

Then add one row to `docs/performance_benchmarks.csv` with the release tag you are
about to cut. Commit it on the release PR, before the tag is pushed — the gate
reads the file at the commit being released, so a row added afterwards does not
count for that release.

## Columns

Field names match `HISTORY_FIELDNAMES` in `scripts/perf_history.py` so a row can be
lifted from the launch-lane history without renaming anything.

| Column | Meaning |
|---|---|
| `release_tag` | the `v*` tag these numbers describe — the only field the gate reads |
| `commit` | short SHA the measurement ran against |
| `timestamp` | ISO-8601 UTC, when the measurement was taken |
| `scenario` | `perf-runner.sh` scenario id, e.g. `installed_clean_shell` |
| `build_kind` | `installed` or `debug` — installed is what ships |
| `protocol_epoch` | measurement protocol; rows are only comparable within one epoch |
| `launch_to_first_prompt_median_ms` | launch until the first shell prompt is ready |
| `repo_hydration_median_ms` | repo list populated |
| `repo_click_to_focus_median_ms` | click a repo until it is focused |
| `workspace_click_to_focus_median_ms` | click a workspace until it is focused |
| `os_version`, `arch`, `model` | host the measurement ran on |
| `notes` | free text — anomalies, why a number moved |

### protocol_epoch is not decoration

Rows from different epochs are not comparable. `legacy-unisolated` runs read
whatever the persistent UserDefaults domain happened to hold and had no guard
against measuring alongside a live instance, so a delta across that boundary mixes
an app change with a protocol change ([#1251](https://github.com/fairchild/workspaces/issues/1251)).
Record the epoch the run actually used and compare within it.

## The seed row

The first row is `v0.23.0` — the last release that shipped — with blank metrics and
a note saying so. It exists to give the gate a starting point rather than to assert
anything about that build's speed. Blank metric cells are honest about being
unmeasured; the gate only reads `release_tag`, so a seed row grants exactly one
release of grace and no more. The next real release needs real numbers.
