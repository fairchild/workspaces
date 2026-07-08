#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run and compare UI-driven and API-driven desktop smoke lanes."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = REPO_ROOT / "output" / "desktop-ui-smoke-parity"
LANES = {
    "ui": {
        "script": REPO_ROOT / "scripts" / "desktop-ui-smoke.sh",
        "output": REPO_ROOT / "output" / "desktop-ui-smoke",
    },
    "api": {
        "script": REPO_ROOT / "scripts" / "api-desktop-ui-smoke.sh",
        "output": REPO_ROOT / "output" / "api-desktop-ui-smoke",
    },
}


@dataclass
class LaneRun:
    lane: str
    index: int
    run_dir: Path
    events_path: Path
    events: list[dict[str, Any]]
    command: list[str]

    @property
    def tokens(self) -> list[str]:
        return [event_token(event) for event in self.events]

    @property
    def comparable_walk(self) -> list[str]:
        return comparable_walk(self.events)

    @property
    def focus_count(self) -> int:
        return sum(1 for event in self.events if event.get("type") == "surface_focused")

    @property
    def focus_timeout_count(self) -> int:
        return sum(1 for event in self.events if event.get("type") == "surface_focus_timed_out")


def event_token(event: dict[str, Any]) -> str:
    kind = event.get("type", "")
    if kind == "terminal_session_attached":
        return f"{kind}:{event.get('selectionKind', 'unknown')}"
    return kind


def comparable_walk(events: list[dict[str, Any]]) -> list[str]:
    """Project a lane to the shared create + workspace-repo-workspace contract."""

    tokens: list[str] = []
    types = [event.get("type") for event in events]
    if "workspace_created" in types:
        tokens.append("workspace_created")
    if "sidebar_updated" in types:
        tokens.append("sidebar_updated")

    attaches = [
        event
        for event in events
        if event.get("type") == "terminal_session_attached"
        and event.get("selectionKind") in {"workspace", "repo"}
    ]

    first_workspace_index = next(
        (index for index, event in enumerate(attaches) if event.get("selectionKind") == "workspace"),
        None,
    )
    if first_workspace_index is not None:
        first_workspace = attaches[first_workspace_index]
        tokens.append(f"terminal_session_attached:{first_workspace.get('selectionKind')}")
        repo_index = next(
            (
                index
                for index, event in enumerate(attaches[first_workspace_index + 1 :], first_workspace_index + 1)
                if event.get("selectionKind") == "repo"
            ),
            None,
        )
        if repo_index is not None:
            repo_attach = attaches[repo_index]
            tokens.append(f"terminal_session_attached:{repo_attach.get('selectionKind')}")
            later_workspace = next(
                (
                    event
                    for event in attaches[repo_index + 1 :]
                    if event.get("selectionKind") == "workspace"
                ),
                None,
            )
            if later_workspace is not None:
                tokens.append(f"terminal_session_attached:{later_workspace.get('selectionKind')}")

    if "scenario_complete" in types:
        tokens.append("scenario_complete")
    return tokens


def load_events(run_dir: Path) -> list[dict[str, Any]]:
    events_path = run_dir / "events.jsonl"
    if not events_path.exists():
        raise RuntimeError(f"events file missing: {events_path}")
    events: list[dict[str, Any]] = []
    for line in events_path.read_text().splitlines():
        line = line.strip()
        if line:
            events.append(json.loads(line))
    if not events:
        raise RuntimeError(f"events file was empty: {events_path}")
    return events


def resolve_latest(output_root: Path) -> Path:
    latest = output_root / "latest"
    if latest.exists():
        return latest.resolve()
    candidates = sorted([path for path in output_root.iterdir() if path.is_dir()])
    if not candidates:
        raise RuntimeError(f"no run directories found under {output_root}")
    return candidates[-1]


def run_command(command: list[str], timeout_seconds: int) -> None:
    print("$ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True, timeout=timeout_seconds)


def run_lane(lane: str, index: int, no_build: bool, timeout_seconds: int) -> LaneRun:
    lane_info = LANES[lane]
    command = [str(lane_info["script"])]
    if no_build:
        command.append("--no-build")
    command.extend(["--timeout-seconds", str(timeout_seconds)])
    run_command(command, timeout_seconds + 30)
    run_dir = resolve_latest(lane_info["output"])
    return LaneRun(
        lane=lane,
        index=index,
        run_dir=run_dir,
        events_path=run_dir / "events.jsonl",
        events=load_events(run_dir),
        command=command,
    )


def build_once() -> None:
    run_command(["swift", "build"], timeout_seconds=300)


def analyze_divergences(runs: list[LaneRun]) -> list[str]:
    divergences: list[str] = []
    expected_walk = [
        "workspace_created",
        "sidebar_updated",
        "terminal_session_attached:workspace",
        "terminal_session_attached:repo",
        "terminal_session_attached:workspace",
        "scenario_complete",
    ]

    for run in runs:
        if run.comparable_walk != expected_walk:
            divergences.append(
                f"{run.lane} run {run.index}: comparable walk was {run.comparable_walk}, "
                f"expected {expected_walk}."
            )
        if run.tokens[-1] != "scenario_complete":
            divergences.append(
                f"{run.lane} run {run.index}: final milestone was {run.tokens[-1]!r}, "
                "not scenario_complete."
            )

    api_runs = [run for run in runs if run.lane == "api"]
    if api_runs:
        divergences.append(
            "Expected API-lane-only handoffs: awaiting_api_create and awaiting_api_select mark where "
            "the host script calls operator verbs."
        )
        divergences.append(
            "Expected residual gap: repo selection is still app-side because the shipped operator API "
            "has workspace.select but no reviewed repo-select verb."
        )

    ui_has_web = any("web_surface_attached" in run.tokens for run in runs if run.lane == "ui")
    api_has_web = any("web_surface_attached" in run.tokens for run in api_runs)
    if ui_has_web and not api_has_web:
        divergences.append(
            "Expected scope difference: the authoritative UI lane still includes the web-surface seam "
            "check; the API parity lane covers the create and workspace-repo-workspace daily-driver walk."
        )

    return divergences


def write_report(report_dir: Path, runs: list[LaneRun], started_at: str) -> Path:
    report_path = report_dir / "parity-report.md"
    divergences = analyze_divergences(runs)
    expected_walk = [
        "workspace_created",
        "sidebar_updated",
        "terminal_session_attached:workspace",
        "terminal_session_attached:repo",
        "terminal_session_attached:workspace",
        "scenario_complete",
    ]
    lines = [
        "# Desktop UI Smoke Parity Report",
        "",
        f"- Started: {started_at}",
        f"- UI runs: {sum(1 for run in runs if run.lane == 'ui')}",
        f"- API runs: {sum(1 for run in runs if run.lane == 'api')}",
        f"- Comparable contract: `{' -> '.join(expected_walk)}`",
        "- `surface_focused` is best-effort; focus timeout counts are reported but do not fail parity.",
        "",
        "## Runs",
        "",
        "| Lane | Run | Directory | Comparable walk | Focus | Focus timeouts |",
        "| --- | ---: | --- | --- | ---: | ---: |",
    ]
    for run in runs:
        lines.append(
            "| "
            + " | ".join(
                [
                    run.lane,
                    str(run.index),
                    f"`{run.run_dir.relative_to(REPO_ROOT)}`",
                    f"`{' -> '.join(run.comparable_walk)}`",
                    str(run.focus_count),
                    str(run.focus_timeout_count),
                ]
            )
            + " |"
        )

    lines.extend(["", "## Full Milestone Streams", ""])
    for run in runs:
        lines.extend(
            [
                f"### {run.lane.upper()} run {run.index}",
                "",
                f"- Events: `{run.events_path.relative_to(REPO_ROOT)}`",
                "",
                "```text",
                " -> ".join(run.tokens),
                "```",
                "",
            ]
        )

    lines.extend(["## Divergences", ""])
    if divergences:
        for divergence in divergences:
            lines.append(f"- {divergence}")
    else:
        lines.append("- None.")

    lines.extend(
        [
            "",
            "## Result",
            "",
        ]
    )
    failed = [
        run
        for run in runs
        if run.comparable_walk != expected_walk or run.tokens[-1] != "scenario_complete"
    ]
    if failed:
        lines.append("Parity failed for the comparable daily-driver milestone contract.")
    else:
        lines.append(
            "Parity passed for the comparable daily-driver milestone contract across all runs."
        )

    report_path.write_text("\n".join(lines) + "\n")
    return report_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=3, help="runs per lane (default: 3)")
    parser.add_argument(
        "--no-build",
        action="store_true",
        help="reuse the current debug binaries; otherwise build once before all runs",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=300,
        help="timeout passed to each smoke lane (default: 300)",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.runs < 1:
        raise SystemExit("--runs must be at least 1")

    started_at = datetime.now().astimezone().isoformat(timespec="seconds")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report_dir = OUTPUT_ROOT / timestamp
    report_dir.mkdir(parents=True, exist_ok=True)
    latest = OUTPUT_ROOT / "latest"
    latest.unlink(missing_ok=True)
    latest.symlink_to(report_dir, target_is_directory=True)

    if not args.no_build:
        build_once()
    lane_no_build = True

    runs: list[LaneRun] = []
    for index in range(1, args.runs + 1):
        runs.append(run_lane("ui", index, lane_no_build, args.timeout_seconds))
        runs.append(run_lane("api", index, lane_no_build, args.timeout_seconds))

    report_path = write_report(report_dir, runs, started_at)
    print(f"Parity report: {report_path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
