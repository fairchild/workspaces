#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Summarize WorkspaceManager `[Perf]` log output.

Works with logs produced by the installed diagnostics launcher and with
existing repo-side perf logs that include `[Perf]` lines.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from perf_schema import app_version_from_binary, canonical_summary, load_contract, numeric_stats


PERF_PATTERN = re.compile(r"\[Perf\]\s+(?P<body>.*)")
FIELD_PATTERN = re.compile(r"(?P<key>[A-Za-z0-9_]+)=(?P<value>\S+)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize WorkspaceManager [Perf] log output."
    )
    parser.add_argument("log_file", type=Path, help="Path to the diagnostic or perf log file.")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON instead of human-readable text.",
    )
    parser.add_argument(
        "--metric",
        action="append",
        default=[],
        help="Only include selected metric names. Can be passed more than once.",
    )
    parser.add_argument(
        "--scenario",
        help="Canonical scenario id. If omitted, infer from the parsed metrics when possible.",
    )
    parser.add_argument(
        "--build-kind",
        choices=["debug", "installed"],
        help="Build kind for the canonical summary. Defaults to an inference based on the log path.",
    )
    parser.add_argument(
        "--protocol-epoch",
        default=None,
        help=(
            "Measurement protocol this capture ran under, recorded on the history row. "
            "Unset means legacy: re-summarizing an archived log must not relabel it as "
            "current. Live captures pass the epoch via perf-runner.sh."
        ),
    )
    parser.add_argument(
        "--app-path",
        type=Path,
        help="Optional app bundle or binary path used to resolve the app version.",
    )
    return parser.parse_args()


def maybe_number(value: str) -> float | None:
    try:
        return float(value)
    except ValueError:
        return None


def parse_perf_line(line: str) -> dict[str, str] | None:
    match = PERF_PATTERN.search(line)
    if match is None:
        return None

    fields: dict[str, str] = {}
    for field in FIELD_PATTERN.finditer(match.group("body")):
        fields[field.group("key")] = field.group("value")
    return fields or None


def summarize_numeric(values: list[float]) -> dict[str, float]:
    return {
        "count": len(values),
        "min": min(values),
        "median": statistics.median(values),
        "max": max(values),
        "mean": statistics.mean(values),
    }


def infer_scenario(
    requested: str | None,
    phase_summaries: dict[str, Any],
    phase_keys: set[str],
) -> str:
    if requested:
        return requested
    if "input_investigation:key_down_handled" in phase_keys:
        return "installed_input_short_capture"

    terminal_summary = phase_summaries.get("terminal_investigation:surface_create_succeeded")
    shell_modes = (
        terminal_summary.get("categorical_fields", {}).get("shell_profile_mode", {})
        if terminal_summary else {}
    )
    if "clean" in shell_modes:
        return "installed_clean_shell"
    if "login" in shell_modes:
        return "installed_login_shell"
    return "unknown"


def infer_build_kind(requested: str | None, log_file: Path, scenario: str) -> str:
    if requested:
        return requested
    if scenario.startswith("debug_"):
        return "debug"
    if "installed" in log_file.name:
        return "installed"
    return "debug"


def build_canonical_metrics(
    all_metrics: dict[str, list[dict[str, str]]],
    phase_summaries: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    metrics: dict[str, dict[str, Any]] = {}

    for metric_name, events in sorted(all_metrics.items()):
        # Deliberately keeps `terminal_focus` samples in the aggregate. A focus close is
        # this metric's *primary* documented end event — "when focus manager successfully
        # sets terminal first responder" — and dropping it would discard the real
        # measurement for every activating launch, leaving only the readiness path that
        # no-activation captures fall back to. The pathological case is narrower than the
        # trigger: a launch that was backgrounded, where focus arrives whenever a human
        # happens to click. That is reported as a finding and left for the reader, because
        # the parser cannot tell "focused promptly" from "focused eventually" without
        # knowing whether anyone was watching (#1399).
        durations = [
            float(duration)
            for duration in (
                event.get("duration_ms")
                for event in events
            )
            if duration is not None and maybe_number(duration) is not None
        ]
        stats = numeric_stats(durations)
        if stats is not None:
            metrics[metric_name] = stats

    input_summary = phase_summaries.get("input_investigation:key_down_handled")
    if input_summary:
        event_age_stats = input_summary["numeric_fields"].get("event_age_ms")
        handler_stats = input_summary["numeric_fields"].get("handler_duration_ms")
        if event_age_stats:
            metrics["input_event_age_ms_median"] = {
                "count": event_age_stats["count"],
                "min": event_age_stats["min"],
                "median": event_age_stats["median"],
                "mean": event_age_stats["mean"],
                "max": event_age_stats["max"],
                "p95": event_age_stats["max"],
                "unit": "ms",
            }
        if handler_stats:
            metrics["input_handler_duration_ms_median"] = {
                "count": handler_stats["count"],
                "min": handler_stats["min"],
                "median": handler_stats["median"],
                "mean": handler_stats["mean"],
                "max": handler_stats["max"],
                "p95": handler_stats["max"],
                "unit": "ms",
            }
    else:
        aggregate_summary = phase_summaries.get("input_investigation:key_down_summary")
        if aggregate_summary:
            age_stats = aggregate_summary["numeric_fields"].get("event_age_median_ms")
            handler_stats = aggregate_summary["numeric_fields"].get("handler_duration_median_ms")
            if age_stats:
                metrics["input_event_age_ms_median"] = {
                    "count": age_stats["count"],
                    "min": age_stats["min"],
                    "median": age_stats["median"],
                    "mean": age_stats["mean"],
                    "max": age_stats["max"],
                    "p95": age_stats["max"],
                    "unit": "ms",
                }
            if handler_stats:
                metrics["input_handler_duration_ms_median"] = {
                    "count": handler_stats["count"],
                    "min": handler_stats["min"],
                    "median": handler_stats["median"],
                    "mean": handler_stats["mean"],
                    "max": handler_stats["max"],
                    "p95": handler_stats["max"],
                    "unit": "ms",
                }

    return metrics


def build_summary(
    log_file: Path,
    metrics_filter: set[str],
    *,
    requested_scenario: str | None,
    requested_build_kind: str | None,
    app_path: Path | None,
    protocol_epoch: str | None = None,
) -> dict[str, Any]:
    lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()

    parsed_events: list[dict[str, Any]] = []
    groups: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    all_metrics: dict[str, list[dict[str, str]]] = defaultdict(list)

    for line in lines:
        fields = parse_perf_line(line)
        if fields is None:
            continue
        metric = fields.get("metric")
        if not metric:
            continue
        if metrics_filter and metric not in metrics_filter:
            continue

        phase = fields.get("phase", "none")
        groups[(metric, phase)].append(fields)
        all_metrics[metric].append(fields)
        parsed_events.append(
            {
                "metric": metric,
                "phase": phase,
                "fields": fields,
            }
        )

    metric_summaries: dict[str, Any] = {}
    for metric, events in all_metrics.items():
        phases = sorted({event.get("phase", "none") for event in events})
        metric_summaries[metric] = {
            "count": len(events),
            "phases": phases,
        }

    phase_summaries: dict[str, Any] = {}
    for (metric, phase), events in sorted(groups.items()):
        numeric_fields: dict[str, list[float]] = defaultdict(list)
        categorical_counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))

        for event in events:
            for key, value in event.items():
                if key in {"metric", "phase"}:
                    continue
                numeric = maybe_number(value)
                if numeric is not None:
                    numeric_fields[key].append(numeric)
                else:
                    categorical_counts[key][value] += 1

        phase_summaries[f"{metric}:{phase}"] = {
            "metric": metric,
            "phase": phase,
            "count": len(events),
            "numeric_fields": {
                key: summarize_numeric(values)
                for key, values in sorted(numeric_fields.items())
            },
            "categorical_fields": {
                key: dict(sorted(values.items()))
                for key, values in sorted(categorical_counts.items())
            },
        }

    findings = derive_findings(phase_summaries)
    scenario = infer_scenario(requested_scenario, phase_summaries, set(phase_summaries))
    build_kind = infer_build_kind(requested_build_kind, log_file, scenario)
    app_version = app_version_from_binary(app_path)
    canonical_metrics = build_canonical_metrics(all_metrics, phase_summaries)
    contract = load_contract()
    # Scoped to the one metric a release row is cut from. A capture can legitimately
    # lack some contract metrics — an installed run does not click a repo, for instance —
    # so a general sweep would cry wolf. The absence of launch_to_first_prompt is never
    # legitimate for a scenario that declares it: it means the launch never reached a
    # prompt inside the capture window, which is a failed measurement, and today that
    # summarizes clean and becomes a blank cell indistinguishable from the seed row's
    # honest blank. #1238's rule, restated in docs/performance_benchmarks.md: a skipped
    # measurement must never be indistinguishable from a passing one. Observed live on
    # 2026-08-30, 3/3 captures (#1399 follow-up).
    launch_metric = "launch_to_first_prompt"
    declares_launch = any(
        entry.get("name") == launch_metric and scenario in entry.get("supported_scenarios", [])
        for entry in contract.get("metrics", [])
    )
    # Failure means the capture holds no evidence the app ever reached a prompt — not
    # merely that the launch interval did not close. A capture can legitimately carry
    # `first_prompt_ready` or `terminal_first_output` without `launch_to_first_prompt`,
    # and those still tell an operator when the terminal became usable. The observed
    # failure had none of the three: the app was up and responsive for 10 s with nothing
    # to say about readiness at all (#1462).
    readiness_evidence = {launch_metric, "first_prompt_ready", "terminal_first_output"}
    measurement_failed = declares_launch and not (readiness_evidence & set(canonical_metrics))
    if measurement_failed:
        findings.append(
            f"MISSING: scenario {scenario} produced no readiness evidence at all — no "
            f"{launch_metric}, first_prompt_ready, or terminal_first_output. The launch "
            "never reached a prompt inside the capture window. This is a failed "
            "measurement, not a fast one; do not record a benchmark row from this run."
        )
    summary = canonical_summary(
        scenario=scenario,
        build_kind=build_kind,
        metrics=canonical_metrics,
        diagnostic_findings=findings,
        artifacts={
            "log_file": str(log_file),
            "line_count": len(lines),
            "perf_event_count": len(parsed_events),
        },
        app_version=app_version,
        contract=contract,
        extra={
            "log_file": str(log_file),
            "line_count": len(lines),
            "perf_event_count": len(parsed_events),
            "phases": phase_summaries,
            "findings": findings,
            "legacy_metric_summaries": metric_summaries,
            # canonical_summary merges `extra` at the top level and then builds
            # `metadata` from summary["metadata"], which is where the history row
            # reads the epoch from.
            **({"metadata": {"protocol_epoch": protocol_epoch}} if protocol_epoch else {}),
        },
    )
    # A finding nobody reads is not a gate. #1238 says a skipped measurement must never
    # be indistinguishable from a passing one, and an exit code is the only part of this
    # the runner and perf-history-record.py actually consult.
    summary["measurement_failed"] = measurement_failed
    summary["metrics_by_phase"] = phase_summaries
    summary["metrics_detected"] = metric_summaries
    summary["findings"] = findings
    return summary


def derive_findings(phase_summaries: dict[str, Any]) -> list[str]:
    findings: list[str] = []

    terminal = phase_summaries.get("terminal_investigation:surface_create_succeeded")
    if terminal:
        duration_stats = terminal["numeric_fields"].get("duration_ms")
        shell_modes = terminal["categorical_fields"].get("shell_profile_mode", {})
        if duration_stats:
            median_ms = duration_stats["median"]
            if median_ms > 1_000:
                findings.append(
                    f"Ghostty surface creation median is {median_ms:.2f} ms. That is large enough to be a user-visible startup cost."
                )
            elif median_ms > 200:
                findings.append(
                    f"Ghostty surface creation median is {median_ms:.2f} ms. That is noticeable and worth comparing between shell modes."
                )
        if shell_modes:
            findings.append(
                "Terminal surface events were captured for shell modes: "
                + ", ".join(sorted(shell_modes))
                + "."
            )

    first_output = phase_summaries.get("terminal_first_output:none")
    if first_output:
        duration_stats = first_output["numeric_fields"].get("duration_ms")
        signals = first_output["categorical_fields"].get("signal", {})
        if duration_stats and duration_stats["median"] > 1_000:
            findings.append(
                f"terminal_first_output median is {duration_stats['median']:.2f} ms. The child shell is not producing an early readiness signal quickly."
            )
        if signals:
            findings.append(
                "terminal_first_output was triggered by signals: "
                + ", ".join(sorted(signals))
                + "."
            )

    prompt_ready = phase_summaries.get("first_prompt_ready:none")
    if prompt_ready:
        duration_stats = prompt_ready["numeric_fields"].get("duration_ms")
        signals = prompt_ready["categorical_fields"].get("signal", {})
        if duration_stats and duration_stats["median"] > 5_000:
            findings.append(
                f"first_prompt_ready median is {duration_stats['median']:.2f} ms. Prompt readiness is still severely delayed after surface creation starts."
            )
        elif duration_stats and duration_stats["median"] > 1_000:
            findings.append(
                f"first_prompt_ready median is {duration_stats['median']:.2f} ms. Prompt readiness is noticeable and worth comparing between clean and login shell runs."
            )
        if signals:
            findings.append(
                "first_prompt_ready was triggered by signals: "
                + ", ".join(sorted(signals))
                + "."
            )

    input_summary = phase_summaries.get("input_investigation:key_down_handled")
    if input_summary:
        event_age_stats = input_summary["numeric_fields"].get("event_age_ms")
        handler_stats = input_summary["numeric_fields"].get("handler_duration_ms")
        surface_missing = input_summary["categorical_fields"].get("surface_missing", {})
        if event_age_stats and event_age_stats["median"] > 50:
            findings.append(
                f"Input event age median is {event_age_stats['median']:.2f} ms. Keys may be arriving late to the app rather than being handled slowly."
            )
        if handler_stats and handler_stats["median"] > 10:
            findings.append(
                f"Input handler median is {handler_stats['median']:.2f} ms. The in-app key path itself is slower than expected."
            )
        if surface_missing.get("true", 0) > 0:
            findings.append(
                "Some key events were recorded without an active terminal surface."
            )

    focus_metrics = [
        summary
        for summary in phase_summaries.values()
        if summary["metric"] == "focus_investigation"
    ]
    if focus_metrics:
        phases = sorted(summary["phase"] for summary in focus_metrics)
        findings.append(
            "Focus diagnostics captured phases: " + ", ".join(phases) + "."
        )

    launch = phase_summaries.get("launch_to_first_prompt:none")
    if launch:
        duration_stats = launch["numeric_fields"].get("duration_ms")
        # Which trigger closed the interval decides what the number means. A
        # `terminal_focus` close on a backgrounded launch measures time-to-foreground —
        # the app sat ready behind another window and the clock kept running — while a
        # readiness trigger measures launch. Both are real; only one belongs in a launch
        # benchmark, and the reader cannot tell them apart from the duration (#1399).
        triggers = launch["categorical_fields"].get("trigger", {})
        if triggers:
            findings.append(
                "launch_to_first_prompt was closed by triggers: "
                + ", ".join(f"{name} ({count})" for name, count in sorted(triggers.items()))
                + "."
            )
            attention_closes = sum(
                count for name, count in triggers.items() if name == "terminal_focus"
            )
            if attention_closes:
                findings.append(
                    f"{attention_closes} launch_to_first_prompt sample(s) closed on terminal_focus, which "
                    "measures time-to-foreground rather than time-to-ready when the launch was backgrounded. "
                    "Exclude those from a launch benchmark or re-measure in the foreground."
                )
        if duration_stats and duration_stats["median"] > 5_000:
            findings.append(
                f"launch_to_first_prompt median is {duration_stats['median']:.2f} ms. Startup is still dominated by terminal readiness or focus."
            )

    if not findings:
        findings.append("No strong automated findings were derived from the parsed [Perf] lines.")

    return findings


def print_text(summary: dict[str, Any]) -> None:
    print("WorkspaceManager perf log summary")
    print(f"  log_file: {summary['log_file']}")
    print(f"  scenario: {summary['scenario']}")
    print(f"  build_kind: {summary['environment']['build_kind']}")
    print(f"  total_lines: {summary['line_count']}")
    print(f"  perf_events: {summary['perf_event_count']}")
    print()

    print("Metrics:")
    if not summary["metrics_detected"]:
        print("- no [Perf] metrics found")
    else:
        for metric, details in sorted(summary["metrics"].items()):
            budget = summary["budget_results"].get(metric, {})
            budget_suffix = ""
            if budget.get("gate_budget_ms") is not None:
                budget_suffix = (
                    f" gate<={budget['gate_budget_ms']}ms"
                    f" status={budget['status']}"
                )
            print(
                f"- {metric}: count={details['count']} min={details['min']:.2f} "
                f"median={details['median']:.2f} p95={details['p95']:.2f} "
                f"max={details['max']:.2f}{budget_suffix}"
            )

    print()
    print("Phase summaries:")
    for key, details in sorted(summary["metrics_by_phase"].items()):
        print(f"- {key}: count={details['count']}")
        for field, stats in sorted(details["numeric_fields"].items()):
            print(
                "  "
                + f"{field}: min={stats['min']:.2f} median={stats['median']:.2f} "
                + f"max={stats['max']:.2f} mean={stats['mean']:.2f}"
            )
        for field, values in sorted(details["categorical_fields"].items()):
            items = ", ".join(f"{name}={count}" for name, count in values.items())
            print("  " + f"{field}: {items}")

    print()
    print("Findings:")
    for finding in summary["findings"]:
        print(f"- {finding}")


def main() -> int:
    args = parse_args()
    summary = build_summary(
        args.log_file,
        set(args.metric),
        requested_scenario=args.scenario,
        requested_build_kind=args.build_kind,
        app_path=args.app_path,
        protocol_epoch=args.protocol_epoch,
    )
    if args.json:
        json.dump(summary, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print_text(summary)
    # The summary is still written on failure — diagnosing why a capture produced no
    # prompt needs it — but the exit code refuses the run, so the runner stops and
    # perf-history-record.py is never handed an empty summary to commit.
    if summary.get("measurement_failed"):
        print(
            "error: no launch_to_first_prompt sample in this capture; refusing to report "
            "it as a successful measurement.",
            file=sys.stderr,
        )
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
