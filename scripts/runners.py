#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""What are the self-hosted GitHub Actions runners on this Mac doing?

Reconciles three sources that drift apart silently:
  * local runner directories (~/.local/share/actions-runner*/.runner)
  * launchd job state (launchctl list + the LaunchAgent's stderr/stdout)
  * GitHub's view (gh api repos/OWNER/REPO/actions/runners)

A runner is healthy only when all three agree. Everything else is drift.
"""

from __future__ import annotations

import argparse
import calendar
import concurrent.futures as cf
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Literal

HOME = Path.home()
RUNNER_GLOB = ".local/share/actions-runner*"
ACTIVITY_LOG = HOME / ".local/share/runner-activity.log"
GITCONFIG_WATCH = HOME / ".local/share/gitconfig-watch/gitconfig-watch.log"
LAUNCH_AGENTS = HOME / "Library/LaunchAgents"
AGENT_LOGS = HOME / "Library/Logs"

Verdict = Literal["busy", "ok", "idle", "offline", "dead", "stale"]

GLYPH: dict[Verdict, tuple[str, str]] = {
    "busy": ("●", "36"),
    "ok": ("●", "32"),
    "idle": ("◐", "33"),
    "offline": ("○", "33"),
    "dead": ("✗", "31"),
    "stale": ("·", "90"),
}

COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def paint(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if COLOR else text


def dim(text: str) -> str:
    return paint(text, "90")


def run(cmd: list[str], timeout: float = 20.0) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def gh_json(path: str) -> dict:
    raw = run(["gh", "api", path])
    try:
        return json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return {}


def ago(ts: float | None) -> str:
    if not ts:
        return "never"
    d = time.time() - ts
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if d >= size:
            return f"{int(d // size)}{unit} ago"
    return "just now"


@dataclass
class Runner:
    directory: Path
    name: str = "?"
    agent_id: int = 0
    repo: str = "?"
    launchd: str = "-"           # running / stopped / not-loaded
    launchd_note: str = ""
    github: str = "-"            # online / offline / busy / absent
    last_job: float | None = None
    hooks: bool = False
    verdict: Verdict = "stale"


@dataclass
class RepoState:
    runners: dict[str, dict] = field(default_factory=dict)
    queued: int = 0


def discover() -> list[Runner]:
    found: list[Runner] = []
    for directory in sorted(HOME.glob(RUNNER_GLOB)):
        if not directory.is_dir():
            continue
        runner = Runner(directory=directory)
        try:
            cfg = json.loads((directory / ".runner").read_text(encoding="utf-8-sig"))
            runner.name = cfg.get("agentName", "?")
            runner.agent_id = int(cfg.get("agentId", 0) or 0)
            url = cfg.get("gitHubUrl", "")
            runner.repo = "/".join(url.rstrip("/").split("/")[-2:]) if url else "?"
        except (OSError, ValueError):
            continue
        env = directory / ".env"
        runner.hooks = env.is_file() and "ACTIONS_RUNNER_HOOK_JOB" in env.read_text(
            encoding="utf-8-sig", errors="ignore"
        )
        workers = list((directory / "_diag").glob("Worker_*.log"))
        if workers:
            runner.last_job = max(w.stat().st_mtime for w in workers)
        found.append(runner)
    return found


def launchd_state(runners: list[Runner]) -> None:
    """Map LaunchAgents to runner dirs by WorkingDirectory, then read launchctl."""
    listing = run(["launchctl", "list"])
    live: dict[str, tuple[str, str]] = {}
    for line in listing.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and "actions.runner" in parts[2]:
            live[parts[2].strip()] = (parts[0].strip(), parts[1].strip())

    by_dir = {str(r.directory): r for r in runners}
    for plist in sorted(LAUNCH_AGENTS.glob("actions.runner.*.plist")):
        try:
            data = plistlib.loads(plist.read_bytes())
        except (OSError, ValueError):
            continue
        label = data.get("Label", plist.stem)
        target = by_dir.get(str(data.get("WorkingDirectory", "")))
        if target is None:
            continue
        if label not in live:
            target.launchd = "not-loaded"
            continue
        pid, status = live[label]
        if pid != "-":
            target.launchd = "running"
        else:
            target.launchd = "stopped"
            target.launchd_note = last_error(label)


REG_DELETED = re.compile(r"registration has been deleted", re.I)


def last_error(label: str) -> str:
    for stream in ("stdout.log", "stderr.log"):
        path = AGENT_LOGS / label / stream
        if not path.is_file():
            continue
        tail = path.read_text(errors="ignore")[-4000:]
        if REG_DELETED.search(tail):
            return "registration deleted server-side"
        for line in reversed(tail.splitlines()):
            if "error" in line.lower() or "exited" in line.lower():
                return line.strip()[:70]
    return ""


def github_state(runners: list[Runner], offline: bool) -> dict[str, RepoState]:
    repos = sorted({r.repo for r in runners if "/" in r.repo})
    state = {repo: RepoState() for repo in repos}
    if offline:
        return state

    calls = [(repo, kind) for repo in repos for kind in ("runners", "queued")]
    paths = {
        "runners": "repos/{}/actions/runners",
        "queued": "repos/{}/actions/runs?status=queued",
    }
    with cf.ThreadPoolExecutor(max_workers=len(calls) or 1) as pool:
        results = pool.map(lambda c: gh_json(paths[c[1]].format(c[0])), calls)
        for (repo, kind), payload in zip(calls, results):
            if kind == "runners":
                for entry in payload.get("runners", []):
                    state[repo].runners[entry["name"]] = entry
            else:
                state[repo].queued = payload.get("total_count", 0)

    for r in runners:
        entry = state.get(r.repo, RepoState()).runners.get(r.name)
        if entry is None:
            r.github = "absent"
        elif entry.get("busy"):
            r.github = "busy"
        else:
            r.github = entry.get("status", "?")
    return state


IDLE_DAYS = 7


def judge(r: Runner, offline: bool) -> Verdict:
    if r.github == "busy":
        return "busy"
    if r.launchd == "stopped" and r.launchd_note:
        return "dead"
    if r.github == "absent" and not offline:
        return "stale"
    if r.github == "offline":
        return "offline"
    if r.launchd == "running" or r.github == "online":
        stale_job = r.last_job is None or time.time() - r.last_job > IDLE_DAYS * 86400
        return "idle" if stale_job else "ok"
    return "stale"


def activity(limit: int) -> list[str]:
    if not ACTIVITY_LOG.is_file():
        return []
    return ACTIVITY_LOG.read_text(errors="ignore").splitlines()[-limit:]


ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")


def last_logged_job() -> float | None:
    """Age of the newest entry *inside* the activity log.

    Deliberately not the file mtime: an unrelated touch or copy moves mtime
    without adding a job, which would report a stale log as fresh.
    """
    for line in reversed(activity(limit=10_000)):
        found = ISO.match(line)
        if found:
            return calendar.timegm(time.strptime(found.group(1), "%Y-%m-%dT%H:%M:%SZ"))
    return None


ENTRY = re.compile(r"^===== (\S+) =====$", re.M)
IN_FLIGHT = re.compile(r"--- CI job processes in flight ---\n(.*?)(?=\n--- |\Z)", re.S)


def gitconfig_writes(limit: int = 3) -> list[tuple[str, bool]]:
    """Last few ~/.gitconfig changes, each flagged with whether CI was running.

    Reads the watcher log written by com.fairchild.gitconfig-watch. Parses
    defensively — that log is owned elsewhere and its format may move.
    """
    if not GITCONFIG_WATCH.is_file():
        return []
    text = GITCONFIG_WATCH.read_text(errors="ignore")
    marks = list(ENTRY.finditer(text))
    entries: list[tuple[str, bool]] = []
    for i, mark in enumerate(marks[-limit:]):
        end = marks[marks.index(mark) + 1].start() if marks.index(mark) + 1 < len(marks) else len(text)
        body = text[mark.end():end]
        found = IN_FLIGHT.search(body)
        blamed = bool(found) and "none" not in found.group(1).strip().lower()
        entries.append((mark.group(1), blamed))
    return entries


def human_bytes(n: int) -> str:
    size = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if size < 1024:
            return f"{size:.0f}{unit}" if unit in ("B", "K") else f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}P"


def disk_usage(runners: Iterable[Runner]) -> list[tuple[str, int]]:
    def size(r: Runner) -> tuple[str, int]:
        out = run(["du", "-sk", str(r.directory)], timeout=120)
        kb = int(out.split()[0]) if out.split() else 0
        return r.name, kb * 1024

    with cf.ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(size, runners))


def render(runners: list[Runner], repos: dict[str, RepoState], args) -> None:
    width = shutil.get_terminal_size((100, 24)).columns
    print(paint("SELF-HOSTED RUNNERS", "1") + dim(f"  {os.uname().nodename}  {time.strftime('%Y-%m-%d %H:%M')}"))
    print(dim("─" * min(width, 96)))

    header = f"  {'RUNNER':<22}{'REPO':<26}{'LAUNCHD':<12}{'GITHUB':<10}{'LAST JOB':<12}HOOK"
    print(dim(header))
    for r in sorted(runners, key=lambda x: (list(GLYPH).index(x.verdict), x.name)):
        glyph, code = GLYPH[r.verdict]
        row = (
            f"{paint(glyph, code)} {r.name:<22}{r.repo:<26}"
            f"{r.launchd:<12}{r.github:<10}{ago(r.last_job):<12}{'yes' if r.hooks else dim('no')}"
        )
        print(row)
        if r.launchd_note:
            print(dim(f"    └─ {r.launchd_note}"))

    live = [r for r in runners if r.verdict in ("ok", "busy", "idle")]
    dead = [r for r in runners if r.verdict == "dead"]
    stale = [r for r in runners if r.verdict == "stale"]
    print()
    print(
        f"  {len(live)} live · {paint(str(len(dead)) + ' dead', '31') if dead else '0 dead'} · "
        f"{len(stale)} stale dirs · {len(runners)} total"
    )

    for repo, state in sorted(repos.items()):
        orphans = [n for n in state.runners if n not in {r.name for r in runners}]
        bits = []
        if state.queued:
            bits.append(paint(f"{state.queued} queued run(s)", "33"))
        if orphans:
            bits.append(f"registered-but-not-local: {', '.join(orphans)}")
        if bits:
            print(f"  {repo}: " + " · ".join(bits))

    problems: list[str] = []
    if dead:
        problems.append(
            f"{len(dead)} LaunchAgent(s) exited and will not retry: "
            + ", ".join(r.name for r in dead)
        )
    hookless = [r for r in live if not r.hooks]
    if hookless:
        problems.append(
            f"{len(hookless)} live runner(s) have no job hooks — their jobs never reach "
            f"runner-activity.log: " + ", ".join(r.name for r in hookless)
        )
    for repo, state in repos.items():
        if state.queued and not any(
            r.repo == repo and r.verdict in ("ok", "busy", "idle") for r in runners
        ):
            problems.append(f"{repo} has {state.queued} queued run(s) and no live runner")

    if problems:
        print()
        print(paint("PROBLEMS", "1;31"))
        for p in problems:
            print(f"  ! {p}")

    log_lines = activity(args.activity)
    print()
    print(paint("RECENT JOBS", "1") + dim(f"  {ACTIVITY_LOG}"))
    if log_lines:
        for line in log_lines:
            print(f"  {line}")
        newest = last_logged_job()
        note = f"  newest entry {ago(newest)}"
        print(dim(note) if newest and time.time() - newest < 7 * 86400
              else paint(note + "  ← no job logged in over a week", "33"))
        mtime = ACTIVITY_LOG.stat().st_mtime
        if newest and mtime - newest > 86400:
            print(dim(f"  (file touched {ago(mtime)} without a new entry — moved or rewritten)"))
    else:
        print(dim("  no activity log (hooks unwired, or no job has ever run)"))

    print()
    print(paint("FOOTPRINT", "1"))
    gitconfig = HOME / ".gitconfig"
    if gitconfig.is_file():
        print(f"  ~/.gitconfig last modified {ago(gitconfig.stat().st_mtime)}")
    writes = gitconfig_writes()
    if writes:
        for stamp, blamed in writes:
            note = paint("CI job in flight", "31") if blamed else dim("no CI job in flight")
            print(f"    └─ {stamp}  {note}")
    elif GITCONFIG_WATCH.is_file():
        print(dim("    └─ watcher installed, no changes recorded yet"))
    else:
        print(dim("    └─ no gitconfig watcher installed"))
    if args.disk:
        sizes = sorted(disk_usage(runners), key=lambda t: -t[1])
        total = sum(s for _, s in sizes)
        print(f"  {human_bytes(total)} across {len(sizes)} runner dirs")
        for name, size in sizes[:5]:
            print(dim(f"    {human_bytes(size):>6}  {name}"))
    else:
        print(dim("  disk: pass --disk (adds a few seconds)"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--offline", action="store_true", help="skip GitHub API calls")
    ap.add_argument("--disk", action="store_true", help="measure runner disk usage")
    ap.add_argument("--activity", type=int, default=8, metavar="N", help="recent job lines (default 8)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    runners = discover()
    if not runners:
        print("no runner directories found under ~/" + RUNNER_GLOB, file=sys.stderr)
        return 1

    launchd_state(runners)
    repos = github_state(runners, args.offline)
    for r in runners:
        r.verdict = judge(r, args.offline)

    if args.json:
        print(json.dumps(
            [
                {
                    "name": r.name, "repo": r.repo, "dir": str(r.directory),
                    "launchd": r.launchd, "launchd_note": r.launchd_note,
                    "github": r.github, "last_job": r.last_job,
                    "hooks": r.hooks, "verdict": r.verdict,
                }
                for r in runners
            ],
            indent=2,
        ))
        return 0

    render(runners, repos, args)
    return 1 if any(r.verdict == "dead" for r in runners) else 0


if __name__ == "__main__":
    sys.exit(main())
