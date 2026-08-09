#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/runners.py — the self-hosted runner status view.

Intent: the tool exists because dead runners were invisible for weeks, so the
behaviour worth locking is that it never reports a dead signal as healthy. Two
classes of test: the verdict a runner gets when its three sources of truth
disagree, and the freshness of the activity log being read from log *content*
rather than file mtime.
"""

from __future__ import annotations

import calendar
import importlib.util
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "runners.py"

spec = importlib.util.spec_from_file_location("runners", SCRIPT_PATH)
assert spec and spec.loader
runners = importlib.util.module_from_spec(spec)
# Registered before exec: @dataclass resolves annotations via sys.modules, and
# this script uses `from __future__ import annotations`.
sys.modules["runners"] = runners
spec.loader.exec_module(runners)


def make(**kwargs) -> "runners.Runner":
    runner = runners.Runner(directory=Path("/tmp/actions-runner-test"))
    for key, value in kwargs.items():
        setattr(runner, key, value)
    return runner


class VerdictTests(unittest.TestCase):
    """A runner is healthy only when local, launchd, and GitHub agree."""

    def test_launchd_exit_with_reason_is_dead_even_though_github_forgot_it(self) -> None:
        # The blue-lume-macos case: registration deleted server-side, launchd
        # gave up permanently. "absent from GitHub" alone would read as merely
        # stale, which understates a service that will never come back.
        runner = make(
            launchd="stopped",
            launchd_note="registration deleted server-side",
            github="absent",
        )
        self.assertEqual(runners.judge(runner, offline=False), "dead")

    def test_running_and_online_but_long_idle_is_idle_not_ok(self) -> None:
        runner = make(
            launchd="running",
            github="online",
            last_job=time.time() - (runners.IDLE_DAYS + 1) * 86400,
        )
        self.assertEqual(runners.judge(runner, offline=False), "idle")

    def test_running_and_online_with_a_recent_job_is_ok(self) -> None:
        runner = make(launchd="running", github="online", last_job=time.time() - 3600)
        self.assertEqual(runners.judge(runner, offline=False), "ok")

    def test_never_ran_counts_as_idle_not_healthy(self) -> None:
        runner = make(launchd="running", github="online", last_job=None)
        self.assertEqual(runners.judge(runner, offline=False), "idle")

    def test_busy_outranks_every_other_signal(self) -> None:
        runner = make(launchd="stopped", launchd_note="whatever", github="busy")
        self.assertEqual(runners.judge(runner, offline=False), "busy")

    def test_local_dir_unknown_to_github_and_launchd_is_stale(self) -> None:
        runner = make(launchd="-", github="absent")
        self.assertEqual(runners.judge(runner, offline=False), "stale")

    def test_offline_mode_does_not_invent_staleness_from_missing_api_data(self) -> None:
        # With --offline every runner looks "absent" because nothing asked
        # GitHub. Calling those stale would report a live runner as abandoned.
        runner = make(launchd="running", github="-", last_job=time.time() - 3600)
        self.assertEqual(runners.judge(runner, offline=True), "ok")


class ActivityFreshnessTests(unittest.TestCase):
    """Regression: freshness comes from log content, never from file mtime.

    An unrelated process touching or rewriting the log moves its mtime without
    adding a job. Reading mtime reported a four-week-stale log as current.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.log = Path(self.tmp.name) / "runner-activity.log"
        self.original = runners.ACTIVITY_LOG
        runners.ACTIVITY_LOG = self.log

    def tearDown(self) -> None:
        runners.ACTIVITY_LOG = self.original
        self.tmp.cleanup()

    def test_reads_newest_timestamp_from_content_ignoring_a_touched_mtime(self) -> None:
        self.log.write_text(
            "2026-07-11T04:18:39Z  START  workspaces  Release/build  v0.23.0\n"
            "2026-07-11T23:45:48Z  DONE   workspaces  Release/build  v0.23.0\n"
        )
        # Simulate the touch that fooled the original implementation.
        now = time.time()
        os.utime(self.log, (now, now))

        expected = calendar.timegm(time.strptime("2026-07-11T23:45:48Z", "%Y-%m-%dT%H:%M:%SZ"))
        self.assertEqual(runners.last_logged_job(), expected)
        self.assertNotAlmostEqual(runners.last_logged_job(), now, delta=86400)

    def test_missing_log_reports_unknown_rather_than_now(self) -> None:
        self.assertIsNone(runners.last_logged_job())

    def test_log_without_parseable_timestamps_reports_unknown(self) -> None:
        self.log.write_text("something that is not a job line\n")
        self.assertIsNone(runners.last_logged_job())


class GitconfigCorrelationTests(unittest.TestCase):
    """A ~/.gitconfig write is only blamed on CI when a job was actually running."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.watch = Path(self.tmp.name) / "gitconfig-watch.log"
        self.original = runners.GITCONFIG_WATCH
        runners.GITCONFIG_WATCH = self.watch

    def tearDown(self) -> None:
        runners.GITCONFIG_WATCH = self.original
        self.tmp.cleanup()

    def test_no_job_in_flight_is_not_blamed_on_ci(self) -> None:
        self.watch.write_text(
            "===== 2026-08-09T15:58:31Z =====\n"
            "--- what changed ---\n-[user]\n"
            "--- CI job processes in flight ---\n  none\n"
            "--- git processes right now ---\n  none\n"
        )
        self.assertEqual(runners.gitconfig_writes(), [("2026-08-09T15:58:31Z", False)])

    def test_worker_in_flight_is_blamed_on_ci(self) -> None:
        self.watch.write_text(
            "===== 2026-08-09T16:10:00Z =====\n"
            "--- what changed ---\n+[user]\n"
            "--- CI job processes in flight ---\n  501 12345 Runner.Worker\n"
            "--- git processes right now ---\n  none\n"
        )
        self.assertEqual(runners.gitconfig_writes(), [("2026-08-09T16:10:00Z", True)])

    def test_absent_watcher_yields_nothing_rather_than_a_false_all_clear(self) -> None:
        self.assertEqual(runners.gitconfig_writes(), [])


class FormattingTests(unittest.TestCase):
    def test_unknown_timestamp_renders_as_never_not_as_now(self) -> None:
        self.assertEqual(runners.ago(None), "never")

    def test_byte_sizes_stay_readable_at_gigabyte_scale(self) -> None:
        self.assertEqual(runners.human_bytes(0), "0B")
        self.assertEqual(runners.human_bytes(2 * 1024**3), "2.0G")


if __name__ == "__main__":
    unittest.main()
