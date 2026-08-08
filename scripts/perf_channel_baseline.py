#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run a channel perf scenario through the performance contract.

Wraps the loose scripts/perf/*/run.sh drivers so the four channel scenarios are
dispatchable via perf-runner.sh with canonical summary.json output and a real
--assert-budget path (#1238). Missing expected metrics fail the assertion.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from perf_schema import canonical_summary, load_contract  # noqa: E402


SCENARIOS: dict[str, dict[str, Any]] = {
    "channel1_hook_ingest_burst": {
        "run_sh": "scripts/perf/channel1-ingest-burst/run.sh",
        "result_file": "rollup.json",
        "mode": "burst",
    },
    "channel1_sidebar_churn": {
        "run_sh": "scripts/perf/channel1-sidebar-churn/run.sh",
        "result_file": "result.json",
        "mode": "single",
        "default_duration": 60,
    },
    "channel1_long_session_memory": {
        "run_sh": "scripts/perf/channel1-long-session-memory/run.sh",
        "result_file": "result.json",
        "mode": "single",
        "default_duration": 600,
    },
    "channel2_statusline_burst": {
        "run_sh": "scripts/perf/channel2-statusline-burst/run.sh",
        "result_file": "rollup.json",
        "mode": "burst",
    },
}

# Ten-minute runs gate against the ten-minute cap; anything longer uses the
# sixty-minute cap from the contract reference.
TEN_MINUTE_CAP_CUTOFF_SECONDS = 900


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", required=True, choices=sorted(SCENARIOS))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument(
        "--duration-seconds",
        type=int,
        default=None,
        help="Steady-state scenario duration. Defaults per scenario (churn 60s, long-session 600s).",
    )
    parser.add_argument("--assert-budget", action="store_true")
    return parser.parse_args()


def contract_units(contract: dict[str, Any]) -> dict[str, str]:
    return {
        metric["name"]: metric.get("unit", "ms")
        for metric in contract.get("metrics", [])
    }


def expected_metrics(contract: dict[str, Any], scenario: str) -> list[str]:
    return [
        metric["name"]
        for metric in contract.get("metrics", [])
        if scenario in metric.get("supported_scenarios", [])
    ]


def run_driver(scenario: str, output_dir: Path, runs: int, duration: int | None) -> Path:
    spec = SCENARIOS[scenario]
    env = os.environ.copy()
    env["OUT_DIR"] = str(output_dir / "driver")
    if spec["mode"] == "burst":
        env["ITER"] = str(runs)
    else:
        env["DURATION"] = str(duration or spec["default_duration"])

    log_path = output_dir / "driver.log"
    result = subprocess.run(
        [str(REPO_ROOT / spec["run_sh"])],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode != 0:
        tail = "\n".join((result.stdout + result.stderr).splitlines()[-40:])
        raise SystemExit(f"channel driver failed ({spec['run_sh']}):\n{tail}")

    result_path = output_dir / "driver" / spec["result_file"]
    if not result_path.is_file():
        raise SystemExit(f"channel driver did not produce {result_path}")
    return result_path


def normalize_metrics(
    scenario: str,
    payload: dict[str, Any],
    units: dict[str, str],
) -> dict[str, dict[str, Any]]:
    """Map driver metric shapes onto canonical stats keyed by bare stat names.

    Burst rollups use `<stat>_ms` keys; steady-state results mix full stats
    dicts and single `{"value": ...}` observations. evaluate_budgets gates on
    bare `median`/`p95`, so every shape converges here.
    """
    runs = int(payload.get("runs", 1))
    normalized: dict[str, dict[str, Any]] = {}
    for name, raw_stats in payload.get("metrics", {}).items():
        unit = units.get(name, "ms")
        stats: dict[str, Any] = {"unit": unit}
        if "value" in raw_stats and len(raw_stats) == 1:
            value = float(raw_stats["value"])
            stats.update({"value": value, "median": value, "max": value, "count": 1})
        else:
            for key, value in raw_stats.items():
                stat_name = key[: -len("_ms")] if key.endswith("_ms") else key
                stats[stat_name] = float(value)
            stats.setdefault("count", runs)
        normalized[name] = stats
    return normalized


def pick_absolute_cap(
    reference: dict[str, Any],
    duration_seconds: float | None,
) -> tuple[str, float] | None:
    if "ten_minute_max_mb" in reference or "sixty_minute_max_mb" in reference:
        if duration_seconds is not None and duration_seconds > TEN_MINUTE_CAP_CUTOFF_SECONDS:
            key = "sixty_minute_max_mb"
        else:
            key = "ten_minute_max_mb"
        if key in reference:
            return key, float(reference[key])
        return None
    for key in ("max_entries", "max_mb", "max_seconds"):
        if key in reference:
            return key, float(reference[key])
    return None


def apply_absolute_caps(summary: dict[str, Any], duration_seconds: float | None) -> None:
    """Gate metrics whose contract reference is an absolute cap.

    evaluate_budgets only understands stat-based references (median/p95); a
    cap-style reference comes back "ungated", which would let --assert-budget
    pass without a verdict. Caps are hard limits, so the gate compares the
    observed value directly, without the budget multiplier.
    """
    for name, budget in summary.get("budget_results", {}).items():
        if budget.get("status") != "ungated":
            continue
        if budget.get("reason") != "reference_baseline_missing_required_stat":
            continue
        reference = budget.get("reference_baseline") or {}
        cap = pick_absolute_cap(reference, duration_seconds)
        if cap is None:
            continue
        cap_key, cap_value = cap
        stats = summary["metrics"].get(name, {})
        observed = stats.get("value", stats.get("median"))
        if observed is None:
            continue
        status = "pass" if float(observed) <= cap_value else "fail"
        summary["budget_results"][name] = {
            "status": status,
            "gate_kind": "absolute_cap",
            "cap_key": cap_key,
            "gate_budget": cap_value,
            "observed_gate": observed,
            "unit": stats.get("unit", ""),
            "reference_baseline": reference,
        }


def mark_missing_expected_metrics(summary: dict[str, Any], contract: dict[str, Any], scenario: str) -> None:
    for name in expected_metrics(contract, scenario):
        if name not in summary.get("metrics", {}):
            summary.setdefault("budget_results", {})[name] = {
                "status": "missing",
                "reason": "expected_by_contract_but_not_measured",
            }


def write_summary(summary: dict[str, Any], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    summary_path = output_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [f"scenario: {summary['scenario']}"]
    for metric_name, stats in summary["metrics"].items():
        unit = stats.get("unit", "")
        parts = [f"{metric_name}:"]
        for stat in ("count", "value", "min", "median", "mean", "p95", "p99", "max"):
            if stat in stats:
                value = stats[stat]
                parts.append(f"{stat}={value:.2f}" if isinstance(value, float) else f"{stat}={value}")
        parts.append(unit)
        lines.append(" ".join(parts))
    for metric_name, budget in summary.get("budget_results", {}).items():
        lines.append(
            f"  {metric_name}: budget_status={budget.get('status')} "
            f"gate={budget.get('gate_budget')} {budget.get('unit', '')} "
            f"observed={budget.get('observed_gate')}"
        )
    (output_dir / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"summary_json={summary_path}")
    print("\n".join(lines))


def assert_budget(summary: dict[str, Any]) -> None:
    violations = [
        f"{name}: {budget.get('status')} "
        f"observed={budget.get('observed_gate')} budget={budget.get('gate_budget')} {budget.get('unit', '')}"
        for name, budget in summary.get("budget_results", {}).items()
        if budget.get("status") in {"fail", "missing"}
    ]
    if violations:
        raise SystemExit("budget assertion failed:\n" + "\n".join(f"  {line}" for line in violations))


def main() -> int:
    args = parse_args()
    output_dir: Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    contract = load_contract()
    result_path = run_driver(args.scenario, output_dir, args.runs, args.duration_seconds)
    payload = json.loads(result_path.read_text(encoding="utf-8"))
    duration_seconds = payload.get("duration_seconds")

    metrics = normalize_metrics(args.scenario, payload, contract_units(contract))
    summary = canonical_summary(
        scenario=args.scenario,
        build_kind="debug",
        metrics=metrics,
        diagnostic_findings=[],
        artifacts={
            "driver_result": str(result_path),
            "driver_log": str(output_dir / "driver.log"),
            "driver_output_dir": str(output_dir / "driver"),
        },
        contract=contract,
        extra={
            "metadata": {
                "runs_requested": args.runs,
                "duration_seconds": duration_seconds,
                "raw_payload_keys": sorted(payload.keys()),
            }
        },
    )
    apply_absolute_caps(summary, duration_seconds)
    mark_missing_expected_metrics(summary, contract, args.scenario)
    write_summary(summary, output_dir)

    if args.assert_budget:
        assert_budget(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
