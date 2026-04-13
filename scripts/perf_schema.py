from __future__ import annotations

import json
import math
import os
import plistlib
import statistics
import subprocess
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT_PATH = REPO_ROOT / "config" / "performance" / "contract.json"


def load_contract(path: Path | None = None) -> dict[str, Any]:
    contract_path = path or DEFAULT_CONTRACT_PATH
    return json.loads(contract_path.read_text(encoding="utf-8"))


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

        gate_reference = float(reference[f"{gate_stat}_ms"])
        diagnostic_reference = float(reference[f"{diagnostic_stat}_ms"])
        gate_budget_ms = _round_budget(gate_reference * gate_multiplier, gate_rounding)
        diagnostic_threshold_ms = _round_budget(
            diagnostic_reference * diagnostic_multiplier,
            diagnostic_rounding,
        )
        observed_median_ms = metric_stats.get("median")
        observed_p95_ms = metric_stats.get("p95")

        status = "pass"
        if observed_median_ms is None:
            status = "missing"
        elif float(observed_median_ms) > gate_budget_ms:
            status = "fail"
        elif observed_p95_ms is not None and float(observed_p95_ms) > diagnostic_threshold_ms:
            status = "warn"

        results[metric_name] = {
            "status": status,
            "gate_budget_ms": gate_budget_ms,
            "diagnostic_threshold_ms": diagnostic_threshold_ms,
            "observed_median_ms": observed_median_ms,
            "observed_p95_ms": observed_p95_ms,
            "reference_baseline": reference,
        }

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
    result = subprocess.run(command, capture_output=True, text=True, check=False)
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
