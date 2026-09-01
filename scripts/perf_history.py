"""Persistence for the perf launch-lane history CSV and dashboard.

Extracted from the scripts/perf-baseline.sh --record heredoc so the baseline
runner and standalone summary ingestion (perf-history-record.py) share one
implementation of row appending and dashboard rendering (#1238).
"""

from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


HISTORY_FIELDNAMES = [
    "scenario",
    "build_kind",
    "timestamp",
    "runs_requested",
    "sleep_seconds",
    "os_version",
    "os_build",
    "arch",
    "model",
    "discovered_repos_median",
    "imported_repos_median",
    "launch_to_first_prompt_median_ms",
    "repo_hydration_median_ms",
    "repo_click_to_focus_median_ms",
    "workspace_click_to_focus_median_ms",
    "launch_to_first_prompt_mean_ms",
    "repo_hydration_mean_ms",
    "repo_click_to_focus_mean_ms",
    "workspace_click_to_focus_mean_ms",
    "activation_to_first_prompt_median_ms",
    "protocol_epoch",
    # What closed the launch samples this row's median was taken over. A row whose cell
    # names `terminal_focus` measured time-to-foreground on a backgrounded launch, not
    # launch — a distinction the duration cannot carry on its own (#1399). Rendered by
    # `perf_schema.launch_trigger_label`, so the debug and installed lanes agree.
    "launch_trigger",
]

# Which measurement protocol produced a row. Rows are only comparable within an epoch:
# `legacy-unisolated` runs read whatever the persistent UserDefaults domain held and had no
# gate against measuring beside a live instance, so a delta across the boundary mixes an app
# change with a protocol change (#1251). Summaries that do not declare an epoch are legacy
# by definition — the field was introduced with the isolated protocol.
LEGACY_PROTOCOL_EPOCH = "legacy-unisolated"

_ROW_METRICS = [
    "launch_to_first_prompt",
    "repo_hydration",
    "repo_click_to_focus",
    "workspace_click_to_focus",
]

_DASHBOARD_METRIC_SPECS = [
    ("launch_to_first_prompt_median_ms", "launch_to_first_prompt"),
    ("repo_hydration_median_ms", "repo_hydration"),
    ("repo_click_to_focus_median_ms", "repo_click_to_focus"),
]


def _metric_stat(summary: dict[str, Any], metric: str, stat: str) -> Any:
    stats = summary.get("metrics", {}).get(metric)
    if stats is None:
        return ""
    value = stats.get(stat)
    return "" if value is None else value


def history_row_from_summary(summary: dict[str, Any], timestamp: str) -> dict[str, Any]:
    metadata = summary.get("metadata", {})
    environment = summary.get("environment", {})
    row: dict[str, Any] = {
        "scenario": summary.get("scenario", ""),
        "build_kind": metadata.get("build_kind") or environment.get("build_kind", ""),
        "timestamp": timestamp,
        "runs_requested": metadata.get("runs_requested", ""),
        "sleep_seconds": metadata.get("sleep_seconds", ""),
        "os_version": metadata.get("os_version") or environment.get("os_version", ""),
        "os_build": metadata.get("os_build") or environment.get("os_build", ""),
        "arch": metadata.get("arch") or environment.get("arch", ""),
        "model": metadata.get("model") or environment.get("machine_model", ""),
        "discovered_repos_median": metadata.get("discovered_repos_median", ""),
        "imported_repos_median": metadata.get("imported_repos_median", ""),
        "activation_to_first_prompt_median_ms": metadata.get("activation_to_first_prompt_median_ms") or "",
        "protocol_epoch": metadata.get("protocol_epoch") or LEGACY_PROTOCOL_EPOCH,
        # Empty when the producer reported no trigger — an older summary, or a capture
        # where the metric never closed. Blank says "unreported", which is what it is;
        # only a producer that saw a trigger can name one.
        "launch_trigger": metadata.get("launch_trigger") or "",
    }
    for metric in _ROW_METRICS:
        row[f"{metric}_median_ms"] = _metric_stat(summary, metric, "median")
        row[f"{metric}_mean_ms"] = _metric_stat(summary, metric, "mean")
    return row


def append_history_row(history_csv_path: Path, row: dict[str, Any]) -> list[dict[str, Any]]:
    existing_rows: list[dict[str, Any]] = []
    if history_csv_path.exists():
        with history_csv_path.open(newline="") as f:
            existing_rows = list(csv.DictReader(f))

    existing_rows.append(row)

    # csv defaults to CRLF, and this rewrites the whole file on every append — so one
    # new row arrived as a diff touching every line that came before it.
    with history_csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=HISTORY_FIELDNAMES, lineterminator="\n")
        writer.writeheader()
        for existing in existing_rows:
            writer.writerow({field: existing.get(field, "") for field in HISTORY_FIELDNAMES})

    with history_csv_path.open(newline="") as f:
        return list(csv.DictReader(f))


def _parse_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _fmt_ms(value: float | None) -> str:
    return f"{value:.2f}" if value is not None else "n/a"


def _delta_text(current: float | None, previous: float | None) -> str:
    if current is None or previous is None or previous == 0:
        return "n/a"
    delta = current - previous
    pct = (delta / previous) * 100.0
    return f"{delta:+.2f} ms ({pct:+.1f}%)"


def _bar(value: float | None, max_value: float, width: int = 24) -> str:
    if value is None or max_value <= 0:
        return "-" * width
    filled = int(round((value / max_value) * width))
    filled = max(1, min(width, filled))
    return "#" * filled + "-" * (width - filled)


def _row_timestamp_key(row: dict[str, Any]) -> datetime:
    try:
        return datetime.strptime(str(row.get("timestamp", "")), "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def render_dashboard(
    rows: list[dict[str, Any]],
    summary: dict[str, Any],
    timestamp: str,
    perf_dir: Path,
) -> str:
    # The CSV is an append log; ad-hoc ingestion (perf-history-record.py, with
    # mtime-derived timestamps) can legitimately append an older run after a
    # newer one. The dashboard therefore orders rows by their timestamp instead
    # of trusting tail position as "latest" (stable sort keeps append order for
    # unparseable timestamps, which sort first).
    rows = sorted(rows, key=_row_timestamp_key)
    metadata = summary.get("metadata", {})
    budget_results = summary.get("budget_results", {})
    latest = rows[-1] if rows else None
    # Delta baselines only mean something within one scenario and one measurement
    # protocol; history mixes debug and installed lanes, and it spans the boundary where
    # the debug lanes started isolating the preferences domain. Compare against the
    # previous row that matches both, so a delta never reports a protocol change as an app
    # change.
    previous = None
    if latest is not None:
        for row in reversed(rows[:-1]):
            same_scenario = row.get("scenario", "") == latest.get("scenario", "")
            same_epoch = (row.get("protocol_epoch") or LEGACY_PROTOCOL_EPOCH) == (
                latest.get("protocol_epoch") or LEGACY_PROTOCOL_EPOCH
            )
            if same_scenario and same_epoch:
                previous = row
                break
    window = rows[-10:]
    latest_report_paths = sorted(perf_dir.glob("release-exception-validation-*.md"))

    lines: list[str] = []
    lines.append("# Performance Dashboard")
    lines.append("")
    lines.append(f"Last updated: `{timestamp}`")
    lines.append("")
    lines.append("## Latest Snapshot")
    lines.append("")
    lines.append("| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |")
    lines.append("|---|---:|---:|---:|---|---|")

    for median_key, metric_name in _DASHBOARD_METRIC_SPECS:
        median_value = _parse_float(latest.get(median_key) if latest else None)
        mean_value = _parse_float(latest.get(f"{metric_name}_mean_ms") if latest else None)
        prev_value = _parse_float(previous.get(median_key) if previous else None)
        budget = budget_results.get(metric_name, {})
        target = budget.get("gate_budget_ms")
        if target is None:
            status = "ungated"
        else:
            status = "pass" if median_value is not None and median_value <= target else "fail"
        lines.append(
            f"| `{metric_name}` | {_fmt_ms(median_value)} | "
            f"{_fmt_ms(mean_value)} | <= {target if target is not None else 'n/a'} | {status} | "
            f"{_delta_text(median_value, prev_value)} |"
        )

    lines.append("")
    lines.append("## Investigated Delta")
    lines.append("")

    if latest is None or previous is None:
        lines.append("- Not enough recorded history yet to compare this snapshot with a previous run.")
    else:
        latest_launch = _parse_float(latest.get("launch_to_first_prompt_median_ms"))
        previous_launch = _parse_float(previous.get("launch_to_first_prompt_median_ms"))
        latest_click = _parse_float(latest.get("repo_click_to_focus_median_ms"))
        previous_click = _parse_float(previous.get("repo_click_to_focus_median_ms"))
        latest_hydration = _parse_float(latest.get("repo_hydration_median_ms"))
        previous_hydration = _parse_float(previous.get("repo_hydration_median_ms"))
        latest_discovered = latest.get("discovered_repos_median") or "n/a"
        previous_discovered = previous.get("discovered_repos_median") or "n/a"
        latest_activation_delay = _parse_float(latest.get("activation_to_first_prompt_median_ms"))
        previous_activation_delay = _parse_float(previous.get("activation_to_first_prompt_median_ms"))
        hydration_gate = budget_results.get("repo_hydration", {}).get("gate_budget_ms") or 0

        if latest_hydration is None:
            hydration_gate_text = "unmeasured in the latest snapshot"
        elif latest_hydration <= hydration_gate:
            hydration_gate_text = "within the configured gate"
        else:
            hydration_gate_text = "outside the configured gate"
        lines.append(
            f"- Portfolio size changed from discovered={previous_discovered} to discovered={latest_discovered}, "
            f"and `repo_hydration` moved {_delta_text(latest_hydration, previous_hydration)} — {hydration_gate_text}."
        )

        lines.append(
            f"- Terminal readiness movement: `launch_to_first_prompt` changed "
            f"{_delta_text(latest_launch, previous_launch)} and `repo_click_to_focus` changed "
            f"{_delta_text(latest_click, previous_click)}."
        )

        if latest_activation_delay is not None and previous_activation_delay is not None:
            lines.append(
                f"- The post-activation ready-to-type gap changed {_delta_text(latest_activation_delay, previous_activation_delay)}, "
                f"from `{previous_activation_delay:.2f} ms` to `{latest_activation_delay:.2f} ms`. "
                "That points to terminal focus/readiness after activation as the main place the extra time moved."
            )
        elif latest_activation_delay is not None:
            lines.append(
                f"- In the latest recorded run, the app reached `applicationDidBecomeActive` a median "
                f"`{latest_activation_delay:.2f} ms` before `launch_to_first_prompt` completed. "
                "That points to post-activation terminal focus/ready-to-type delay rather than repository import."
            )

        if latest_report_paths:
            lines.append(
                f"- Broader release-candidate context, including `activate` and `new_workspace_sheet_ready` "
                f"measurements, is recorded in `./{latest_report_paths[-1].name}`."
            )

    lines.append("")
    lines.append("## Trend (Last 10 Runs)")
    lines.append("")
    lines.append("| Timestamp | Scenario | Launch (ms) | Hydration (ms) | Repo Click-to-Focus (ms) | Workspace Click-to-Focus (ms) |")
    lines.append("|---|---|---:|---:|---:|---:|")
    for row in window:
        launch_value = _parse_float(row.get("launch_to_first_prompt_median_ms"))
        hydration_value = _parse_float(row.get("repo_hydration_median_ms"))
        click_value = _parse_float(row.get("repo_click_to_focus_median_ms"))
        ws_click_value = _parse_float(row.get("workspace_click_to_focus_median_ms"))
        lines.append(
            f"| {row['timestamp']} | "
            f"{row.get('scenario') or 'n/a'} | "
            f"{_fmt_ms(launch_value)} | "
            f"{_fmt_ms(hydration_value)} | "
            f"{_fmt_ms(click_value)} | "
            f"{_fmt_ms(ws_click_value)} |"
        )

    lines.append("")
    lines.append("## Visual Bars (Last 10 Run Window)")
    lines.append("")

    for median_key, metric_name in _DASHBOARD_METRIC_SPECS:
        current = _parse_float(latest.get(median_key) if latest else None)
        target = budget_results.get(metric_name, {}).get("gate_budget_ms")
        target_pct = (current / target * 100.0) if current is not None and target is not None and target > 0 else None
        target_pct_text = f"{target_pct:.1f}%" if target_pct is not None else "n/a"
        target_text = f"{target:.0f}" if target is not None else "n/a"
        lines.append(f"`{metric_name}` target <= {target_text} ms")
        lines.append("")
        lines.append(f"current {_fmt_ms(current)} ms ({target_pct_text} of target)")
        lines.append(f"[{_bar(current, target or 0)}]")
        lines.append("")

    environment = summary.get("environment", {})
    lines.append("## Run Context")
    lines.append("")
    lines.append(
        f"- OS: `{metadata.get('os_version') or environment.get('os_version', 'n/a')}` "
        f"(build `{metadata.get('os_build') or environment.get('os_build', 'n/a')}`)"
    )
    lines.append(
        f"- Hardware: `{metadata.get('arch') or environment.get('arch', 'n/a')}` / "
        f"`{metadata.get('model') or environment.get('machine_model', 'n/a')}`"
    )
    lines.append(
        f"- Portfolio context: discovered={metadata.get('discovered_repos_median', 'n/a')} "
        f"imported={metadata.get('imported_repos_median', 'n/a')}"
    )
    lines.append(
        f"- Sample setup: runs={metadata.get('runs_requested', 'n/a')}, "
        f"sleep={metadata.get('sleep_seconds', 'n/a')}s"
    )
    lines.append("")
    lines.append("## Recording Cadence")
    lines.append("")
    lines.append(
        "- Measurement is opt-in on the owner's laptop, one approved session at a time: "
        "`./scripts/perf-baseline.sh 3 6 --record --assert-budget`, then commit the refreshed "
        "`docs/performance/` files. No schedule runs this — read staleness off the `Last updated` "
        "timestamp above, not off a workflow's colour. Protocol and hygiene preconditions: "
        "`docs/decisions/perf-measurement-laptop-optin.md`."
    )
    lines.append(
        "- Ad-hoc canonical summaries (e.g. re-baseline output dirs) are appended with "
        "`uv run --script scripts/perf-history-record.py --summary <summary.json>`."
    )
    lines.append("")
    lines.append("## Metric Definitions")
    lines.append("")
    lines.append("- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)")
    lines.append("- `repo_hydration`: auto-discovery/import pass for `~/code` repos")
    lines.append("- `repo_click_to_focus`: repo row click -> focused terminal session restore")
    lines.append("- `workspace_click_to_focus`: workspace row click -> focused terminal session restore")
    lines.append("- Detailed flow diagrams: `./metrics-reference.md`")

    return "\n".join(lines) + "\n"


def record_summary(summary: dict[str, Any], root_dir: Path, timestamp: str) -> dict[str, Path]:
    perf_dir = root_dir / "docs" / "performance"
    perf_dir.mkdir(parents=True, exist_ok=True)
    history_csv_path = perf_dir / "metrics-history.csv"
    dashboard_path = perf_dir / "dashboard.md"
    latest_json_path = perf_dir / "latest-summary.json"

    latest_json_path.write_text(json.dumps(summary, indent=2) + "\n")
    rows = append_history_row(history_csv_path, history_row_from_summary(summary, timestamp))
    dashboard_path.write_text(render_dashboard(rows, summary, timestamp, perf_dir))

    return {
        "history_csv": history_csv_path,
        "dashboard_md": dashboard_path,
        "latest_json": latest_json_path,
    }
