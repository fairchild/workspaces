from __future__ import annotations

import json
import math
import os
import plistlib
import re
import statistics
import subprocess
from collections.abc import Iterable
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT_PATH = REPO_ROOT / "config" / "performance" / "contract.json"

# Click-to-focus intervals only measure latency when they end in a
# terminal-success outcome. Every other outcome (superseded, web_source_selected,
# repo_overview_selected, ...) is an abandoned interval whose elapsed wall time
# is idle time, not latency. The allowlist is intentional: a new cancel reason
# cannot silently rejoin the sample pool.
CLICK_TO_FOCUS_METRICS = frozenset({"repo_click_to_focus", "workspace_click_to_focus"})
CLICK_TO_FOCUS_SUCCESS_OUTCOMES = frozenset({"prompt_ready", "focused"})

# The trigger that names a launch measurement as attention rather than readiness. A
# `terminal_focus` close stops the clock when something brought the app forward, so on a
# backgrounded launch the duration is time-to-foreground (#1399).
ATTENTION_LAUNCH_TRIGGER = "terminal_focus"

_DURATION_LINE_PATTERN = re.compile(
    r"metric=(?P<metric>[a-z_]+) duration_ms=(?P<duration>[0-9]+(?:\.[0-9]+)?)"
)
_OUTCOME_PATTERN = re.compile(r"outcome=(?P<outcome>[A-Za-z0-9_]+)")


def load_contract(path: Path | None = None) -> dict[str, Any]:
    contract_path = path or DEFAULT_CONTRACT_PATH
    return json.loads(contract_path.read_text(encoding="utf-8"))


def measured_duration_samples(text: str) -> list[tuple[str, float]]:
    """Yield (metric, duration_ms) pairs that represent measured latency.

    Abandoned click-to-focus intervals log `status=abandoned elapsed_ms=...`
    and never match; this filter additionally rejects any click-to-focus
    `duration_ms` line (from older builds or future regressions) whose outcome
    is not a terminal success.
    """
    samples: list[tuple[str, float]] = []
    for line in text.splitlines():
        match = _DURATION_LINE_PATTERN.search(line)
        if match is None:
            continue
        metric = match.group("metric")
        if metric in CLICK_TO_FOCUS_METRICS:
            outcome = _OUTCOME_PATTERN.search(line)
            if outcome is None or outcome.group("outcome") not in CLICK_TO_FOCUS_SUCCESS_OUTCOMES:
                continue
        samples.append((metric, float(match.group("duration"))))
    return samples


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        raise ValueError("percentile() requires at least one value")
    if len(values) == 1:
        return values[0]

    sorted_values = sorted(values)
    rank = (len(sorted_values) - 1) * (percentile_value / 100.0)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return sorted_values[lower]
    lower_weight = upper - rank
    upper_weight = rank - lower
    return (sorted_values[lower] * lower_weight) + (sorted_values[upper] * upper_weight)


def numeric_stats(values: list[float], unit: str = "ms") -> dict[str, Any] | None:
    if not values:
        return None
    return {
        "count": len(values),
        "min": min(values),
        "median": statistics.median(values),
        "mean": statistics.mean(values),
        "max": max(values),
        "p95": percentile(values, 95),
        "unit": unit,
    }


def launch_trigger_label(triggers: Iterable[str | None]) -> str:
    """How a recorded row names what closed its `launch_to_first_prompt` samples.

    A median is only as meaningful as the samples under it, and `launch_to_first_prompt`
    can close on either a readiness signal or `terminal_focus` — the second measures
    time-to-foreground on a backgrounded launch. Duration alone cannot tell them apart,
    so the row carries the triggers and a reader (or a `grep terminal_focus`) can (#1399).

    Both parsers call this rather than formatting their own, so a `launch_trigger` cell
    means the same thing whichever lane produced the row — the debug one via
    `perf-baseline.sh`, the release one via the optimization skill's summarizer.

    The values pass through from the log line: the vocabulary belongs to the Swift call
    sites of `PerformanceSignposts.endLaunchToFirstPromptIfNeeded(trigger:)`, and a
    normalizing enum here would mislabel a newly added trigger until someone noticed.
    Distinct triggers are joined rather than reduced to one, because a median taken over
    a mix is exactly the row that most needs saying so.
    """
    present = sorted({trigger for trigger in triggers if trigger})
    return "+".join(present)


def metric_aliases(summary: dict[str, Any]) -> dict[str, Any]:
    return {
        metric_name: metric_stats
        for metric_name, metric_stats in summary.get("metrics", {}).items()
    }


def _round_budget(value: float, mode: str) -> int:
    if mode == "ceil":
        return math.ceil(value)
    if mode == "floor":
        return math.floor(value)
    if mode == "round":
        return round(value)
    raise ValueError(f"Unsupported rounding mode: {mode}")


def _metric_reference(contract: dict[str, Any], scenario: str, metric_name: str) -> dict[str, Any] | None:
    for metric in contract.get("metrics", []):
        if metric.get("name") != metric_name:
            continue
        return metric.get("reference_baselines", {}).get(scenario)
    return None


def _reference_stat_value(reference: dict[str, Any], stat: str, unit: str) -> float | None:
    normalized_unit = unit.lower()
    candidates: list[str] = []
    if normalized_unit in {"ms", "millisecond", "milliseconds"}:
        candidates.append(f"{stat}_ms")
    elif normalized_unit in {"mb", "mib"}:
        candidates.append(f"{stat}_mb")
    candidates.append(stat)

    for key in candidates:
        value = reference.get(key)
        if value is not None:
            return float(value)
    return None


def evaluate_budgets(
    contract: dict[str, Any],
    scenario: str,
    metrics: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    formula = contract.get("budget_formula", {})
    gate_formula = formula.get("gate", {})
    diagnostic_formula = formula.get("diagnostic", {})

    gate_stat = gate_formula.get("stat", "median")
    gate_multiplier = float(gate_formula.get("multiplier", 1.25))
    gate_rounding = gate_formula.get("rounding", "ceil")

    diagnostic_stat = diagnostic_formula.get("stat", "p95")
    diagnostic_multiplier = float(diagnostic_formula.get("multiplier", 1.5))
    diagnostic_rounding = diagnostic_formula.get("rounding", "ceil")

    results: dict[str, dict[str, Any]] = {}
    for metric_name, metric_stats in metrics.items():
        reference = _metric_reference(contract, scenario, metric_name)
        if reference is None:
            results[metric_name] = {
                "status": "ungated",
                "reason": "no_reference_baseline",
            }
            continue

        unit = str(metric_stats.get("unit", "ms"))
        gate_reference = _reference_stat_value(reference, gate_stat, unit)
        diagnostic_reference = _reference_stat_value(reference, diagnostic_stat, unit)
        if gate_reference is None or diagnostic_reference is None:
            results[metric_name] = {
                "status": "ungated",
                "reason": "reference_baseline_missing_required_stat",
                "reference_baseline": reference,
            }
            continue

        gate_budget = _round_budget(gate_reference * gate_multiplier, gate_rounding)
        diagnostic_threshold = _round_budget(
            diagnostic_reference * diagnostic_multiplier,
            diagnostic_rounding,
        )
        observed_gate = metric_stats.get(gate_stat)
        observed_diagnostic = metric_stats.get(diagnostic_stat)

        status = "pass"
        if observed_gate is None:
            status = "missing"
        elif float(observed_gate) > gate_budget:
            status = "fail"
        elif observed_diagnostic is not None and float(observed_diagnostic) > diagnostic_threshold:
            status = "warn"

        result = {
            "status": status,
            "gate_budget": gate_budget,
            "diagnostic_threshold": diagnostic_threshold,
            "observed_gate": observed_gate,
            "observed_diagnostic": observed_diagnostic,
            "gate_stat": gate_stat,
            "diagnostic_stat": diagnostic_stat,
            "unit": unit,
            "reference_baseline": reference,
        }
        if unit.lower() in {"ms", "millisecond", "milliseconds"}:
            result.update({
                "gate_budget_ms": gate_budget,
                "diagnostic_threshold_ms": diagnostic_threshold,
                "observed_median_ms": metric_stats.get("median"),
                "observed_p95_ms": metric_stats.get("p95"),
            })
        results[metric_name] = result

    return results


def detect_environment(
    *,
    build_kind: str,
    app_version: str | None = None,
    os_version: str | None = None,
    os_build: str | None = None,
    machine_model: str | None = None,
    arch: str | None = None,
) -> dict[str, Any]:
    return {
        "build_kind": build_kind,
        "app_version": app_version,
        "os_version": os_version or read_command_text(["sw_vers", "-productVersion"]),
        "os_build": os_build or read_command_text(["sw_vers", "-buildVersion"]),
        "machine_model": machine_model or read_command_text(["sysctl", "-n", "hw.model"]),
        "arch": arch or read_command_text(["uname", "-m"]),
    }


def read_command_text(command: list[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def app_version_from_binary(binary_path: Path | None) -> str | None:
    if binary_path is None:
        return None

    resolved = binary_path.expanduser().resolve()
    if resolved.name == "WorkspaceManager" and resolved.parent.name == "MacOS":
        info_plist = resolved.parents[2] / "Info.plist"
    elif resolved.name == "Info.plist":
        info_plist = resolved
    else:
        info_plist = resolved / "Contents" / "Info.plist"

    if not info_plist.is_file():
        return None

    with info_plist.open("rb") as handle:
        info = plistlib.load(handle)
    short_version = info.get("CFBundleShortVersionString")
    build_version = info.get("CFBundleVersion")
    if short_version and build_version:
        return f"{short_version} ({build_version})"
    if short_version:
        return str(short_version)
    if build_version:
        return str(build_version)
    return None


def canonical_summary(
    *,
    scenario: str,
    build_kind: str,
    metrics: dict[str, dict[str, Any]],
    diagnostic_findings: list[str],
    artifacts: dict[str, Any],
    app_version: str | None = None,
    os_version: str | None = None,
    os_build: str | None = None,
    machine_model: str | None = None,
    arch: str | None = None,
    contract: dict[str, Any] | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    loaded_contract = contract or load_contract()
    summary = {
        "schema_version": 1,
        "scenario": scenario,
        "environment": detect_environment(
            build_kind=build_kind,
            app_version=app_version,
            os_version=os_version,
            os_build=os_build,
            machine_model=machine_model,
            arch=arch,
        ),
        "metrics": metrics,
        "diagnostic_findings": diagnostic_findings,
        "budget_results": evaluate_budgets(loaded_contract, scenario, metrics),
        "artifacts": artifacts,
    }
    if extra:
        summary.update(extra)
    summary.update(metric_aliases(summary))
    metadata = dict(summary.get("metadata", {}))
    metadata.update({
        "schema_version": summary["schema_version"],
        "scenario": scenario,
        "build_kind": build_kind,
        "timestamp": os.environ.get("PERF_SUMMARY_TIMESTAMP"),
    })
    summary["metadata"] = metadata
    return summary
