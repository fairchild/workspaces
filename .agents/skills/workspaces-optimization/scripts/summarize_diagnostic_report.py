#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Summarize a Workspaces diagnostic report zip.

Reads the exported diagnostic bundle and prints a concise interpretation that is
useful for agent-driven or manual performance triage.
"""

from __future__ import annotations

import argparse
import json
import sys
import zipfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


@dataclass
class MetricEvent:
    metric: str
    duration_ms: float
    timestamp: datetime | None
    labels: dict[str, str]

    @property
    def started_at(self) -> datetime | None:
        if self.timestamp is None:
            return None
        return self.timestamp - timedelta(milliseconds=self.duration_ms)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize a Workspaces diagnostic report zip."
    )
    parser.add_argument("report_zip", type=Path, help="Path to workspaces-report-*.zip")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the summary as JSON instead of human-readable text.",
    )
    return parser.parse_args()


def parse_iso8601(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def load_zip_text(archive: zipfile.ZipFile, name: str) -> str | None:
    try:
        return archive.read(name).decode("utf-8", errors="replace")
    except KeyError:
        return None


def load_report(path: Path) -> tuple[dict[str, Any], str | None, str | None]:
    with zipfile.ZipFile(path) as archive:
        raw_report = load_zip_text(archive, "report.json")
        if raw_report is None:
            raise SystemExit(f"report.json is missing from {path}")
        return json.loads(raw_report), load_zip_text(archive, "system-profile.txt"), load_zip_text(
            archive, "recent-logs.txt"
        )


def parse_events(report: dict[str, Any]) -> list[MetricEvent]:
    raw_events = report.get("startupDiagnostics", {}).get("events", [])
    events: list[MetricEvent] = []
    for event in raw_events:
        metric = str(event.get("metric", "unknown"))
        duration_ms = float(event.get("durationMs", 0.0))
        timestamp = parse_iso8601(event.get("timestamp"))
        labels = {
            str(key): str(value)
            for key, value in dict(event.get("labels", {})).items()
        }
        events.append(
            MetricEvent(
                metric=metric,
                duration_ms=duration_ms,
                timestamp=timestamp,
                labels=labels,
            )
        )
    return events


def find_event(events: list[MetricEvent], metric: str) -> MetricEvent | None:
    for event in events:
        if event.metric == metric:
            return event
    return None


def recent_logs_empty(recent_logs: str | None) -> bool:
    if recent_logs is None:
        return True
    lines = [line.strip() for line in recent_logs.splitlines() if line.strip()]
    if not lines:
        return True
    if len(lines) == 1 and lines[0].startswith("Timestamp"):
        return True
    return False


def build_summary(report: dict[str, Any], system_profile: str | None, recent_logs: str | None) -> dict[str, Any]:
    events = parse_events(report)
    launch = find_event(events, "launch_to_first_prompt")
    hydration = find_event(events, "repo_hydration")
    first_output = find_event(events, "terminal_first_output")
    prompt_ready = find_event(events, "first_prompt_ready")

    diagnostics = report.get("startupDiagnostics", {})
    system = report.get("system", {})

    findings: list[str] = []
    next_steps: list[str] = []

    if launch and hydration and launch.duration_ms > 5_000 and hydration.duration_ms < 100:
        findings.append(
            "Launch slowdown is concentrated in terminal readiness or focus, not repo hydration."
        )

    if launch and launch.duration_ms > 20_000:
        findings.append(
            "First prompt latency is extreme for this app and is more consistent with host-side blocking, login-shell overhead, or a major terminal/focus stall than with normal app startup cost."
        )

    if recent_logs_empty(recent_logs):
        findings.append(
            "recent-logs.txt is empty or near-empty, so this report is missing useful runtime context."
        )
        next_steps.append(
            "Capture a direct app run with `[Perf]` output and pair it with a shell-startup probe on the same machine. If this report came from an older build, re-export from a newer build that broadens recent-log capture."
        )

    if launch:
        next_steps.append(
            "Compare raw login-shell startup against a clean shell in the slow repo and in the home directory."
        )

    if launch and hydration:
        next_steps.append(
            "If Terminal.app is fast but Workspaces is slow, inspect Ghostty surface creation and focus timing."
        )

    if first_output and prompt_ready and prompt_ready.duration_ms > first_output.duration_ms + 1_000:
        findings.append(
            "The shell emitted an early readiness signal well before prompt-ready, so delay remains after the first terminal response."
        )

    app_path = None
    if system_profile:
        for line in system_profile.splitlines():
            stripped = line.strip()
            if stripped.startswith("Path: "):
                app_path = stripped.removeprefix("Path: ")
                break

    return {
        "report_path": str(report.get("_report_path", "")),
        "generated_at": report.get("generatedAt"),
        "system": {
            "model": system.get("hardwareModel"),
            "architecture": system.get("architecture"),
            "memory_gb": system.get("physicalMemoryGB"),
            "processors": system.get("processorCount"),
            "os_version": system.get("osVersion"),
            "os_build": system.get("osBuild"),
        },
        "app": {
            "version": diagnostics.get("appVersion"),
            "build_number": diagnostics.get("buildNumber"),
            "app_path": app_path,
        },
        "metrics": {
            "launch_to_first_prompt_ms": launch.duration_ms if launch else None,
            "launch_started_at": launch.started_at.isoformat() if launch and launch.started_at else None,
            "launch_recorded_at": launch.timestamp.isoformat() if launch and launch.timestamp else None,
            "repo_hydration_ms": hydration.duration_ms if hydration else None,
            "repo_hydration_recorded_at": hydration.timestamp.isoformat() if hydration and hydration.timestamp else None,
            "repo_hydration_labels": hydration.labels if hydration else None,
            "terminal_first_output_ms": first_output.duration_ms if first_output else None,
            "terminal_first_output_labels": first_output.labels if first_output else None,
            "first_prompt_ready_ms": prompt_ready.duration_ms if prompt_ready else None,
            "first_prompt_ready_labels": prompt_ready.labels if prompt_ready else None,
        },
        "recent_logs_empty": recent_logs_empty(recent_logs),
        "findings": findings,
        "next_steps": next_steps,
    }


def print_text(summary: dict[str, Any]) -> None:
    system = summary["system"]
    app = summary["app"]
    metrics = summary["metrics"]

    print("Workspaces diagnostic summary")
    print(f"  model: {system['model']} ({system['architecture']})")
    print(f"  macOS: {system['os_version']} ({system['os_build']})")
    print(f"  app: {app['version']} ({app['build_number']})")
    if app["app_path"]:
        print(f"  path: {app['app_path']}")
    if metrics["launch_to_first_prompt_ms"] is not None:
        print(f"  launch_to_first_prompt: {metrics['launch_to_first_prompt_ms']:.2f} ms")
    if metrics["repo_hydration_ms"] is not None:
        print(f"  repo_hydration: {metrics['repo_hydration_ms']:.2f} ms")
    if metrics["terminal_first_output_ms"] is not None:
        signal = metrics["terminal_first_output_labels"].get("signal", "unknown")
        print(f"  terminal_first_output: {metrics['terminal_first_output_ms']:.2f} ms ({signal})")
    if metrics["first_prompt_ready_ms"] is not None:
        signal = metrics["first_prompt_ready_labels"].get("signal", "unknown")
        print(f"  first_prompt_ready: {metrics['first_prompt_ready_ms']:.2f} ms ({signal})")
    if metrics["launch_started_at"]:
        started = parse_iso8601(metrics["launch_started_at"])
        if started is not None:
            local = started.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
            print(f"  launch_started_at: {local}")

    print()
    print("Findings:")
    findings = summary["findings"] or ["No strong automated findings."]
    for finding in findings:
        print(f"- {finding}")

    print()
    print("Suggested next steps:")
    next_steps = summary["next_steps"] or ["No automatic next steps."]
    for step in next_steps:
        print(f"- {step}")


def main() -> int:
    args = parse_args()
    report, system_profile, recent_logs = load_report(args.report_zip)
    report["_report_path"] = str(args.report_zip)
    summary = build_summary(report, system_profile, recent_logs)

    if args.json:
        json.dump(summary, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print_text(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
