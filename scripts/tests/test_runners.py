#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for scripts/runners.py — the self-hosted runner status view.

Intent: the tool exists because dead runners were invisible for weeks, so the
behaviour worth locking is that it never reports a dead signal as healthy. Three
classes of test: the verdict a runner gets when its three sources of truth
disagree, the freshness of the activity log being read from log *content* rather
than file mtime, and a finished job never reading as a passing one.
"""

from __future__ import annotations

import calendar
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "runners.py"
COMPLETE_HOOK = REPO_ROOT / "scripts" / "runner-notify-complete.sh"

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


class JobOutcomeTests(unittest.TestCase):
    """"The job ended" is not "the job passed", and the log line cannot say which.

    A failed v0.24.0 release was read as a successful one because the completed
    hook wrote DONE the moment the job stopped. Job status is API-only, so the
    outcome shown here comes from GitHub or is reported as unknown.
    """

    END = "2026-08-10T02:04:48Z  END    workspaces      Release/build  v0.24.0  run=31345686688"
    RERUN = END + "  attempt=2"
    LEGACY = "2026-08-10T02:04:48Z  DONE   workspaces      Release/build  v0.24.0"
    START = "2026-08-10T01:59:00Z  START  workspaces      Release/build  v0.24.0"

    def test_failed_run_reads_as_failure_not_as_completion(self) -> None:
        ref = runners.job_ref(self.END)
        assert ref is not None
        rendered = runners.outcome(self.END, {ref: "failure"})
        self.assertIn("failure", rendered)
        self.assertNotIn("success", rendered)

    def test_confirmed_success_says_so(self) -> None:
        ref = runners.job_ref(self.END)
        assert ref is not None
        self.assertIn("success", runners.outcome(self.END, {ref: "success"}))

    def test_unresolved_run_is_unknown_rather_than_a_pass(self) -> None:
        # GitHub unreachable, --offline, or a run since deleted.
        self.assertIn("unknown", runners.outcome(self.END, {}))
        self.assertNotIn("success", runners.outcome(self.END, {}))

    def test_legacy_done_lines_claim_nothing(self) -> None:
        # Seven months of history predate run ids; they must stay unresolvable
        # rather than borrow a verdict from a neighbouring line.
        self.assertIsNone(runners.job_ref(self.LEGACY))
        self.assertIn("unknown", runners.outcome(self.LEGACY, {}))

    def test_start_lines_carry_no_outcome_at_all(self) -> None:
        self.assertEqual(runners.outcome(self.START, {}), "")

    def test_a_rerun_does_not_inherit_the_first_attempts_verdict(self) -> None:
        first, again = runners.job_ref(self.END), runners.job_ref(self.RERUN)
        assert first is not None and again is not None
        self.assertNotEqual(first, again)
        self.assertIn("unknown", runners.outcome(self.RERUN, {first: "success"}))

    def test_attempts_resolve_against_the_attempt_endpoint(self) -> None:
        first, again = runners.job_ref(self.END), runners.job_ref(self.RERUN)
        assert first is not None and again is not None
        self.assertEqual(
            first.api_path("fairchild/workspaces"),
            "repos/fairchild/workspaces/actions/runs/31345686688",
        )
        self.assertEqual(
            again.api_path("fairchild/workspaces"),
            "repos/fairchild/workspaces/actions/runs/31345686688/attempts/2",
        )

    def test_offline_resolves_nothing_instead_of_guessing(self) -> None:
        runner = make(repo="fairchild/workspaces")
        self.assertEqual(runners.conclusions([self.END], [runner], offline=True), {})

    def test_a_repo_with_no_local_runner_is_not_queried(self) -> None:
        # Nothing maps "workspaces" to an owner, so there is no URL to ask.
        self.assertEqual(runners.conclusions([self.END], [], offline=False), {})


class CompletedHookTests(unittest.TestCase):
    """The hook records identity and never fails the job it is reporting on."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def fire(self, **env: str) -> str:
        result = subprocess.run(
            ["bash", str(COMPLETE_HOOK)],
            capture_output=True,
            text=True,
            env={"HOME": str(self.home), "PATH": os.environ.get("PATH", ""), **env},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.home / ".local/share/runner-activity.log"
        return log.read_text() if log.is_file() else ""

    def test_logs_the_end_of_the_job_and_the_run_to_ask_about(self) -> None:
        line = self.fire(
            GITHUB_REPOSITORY="fairchild/workspaces",
            GITHUB_JOB="build-sign-notarize-release",
            GITHUB_WORKFLOW="Release",
            GITHUB_REF_NAME="v0.24.0",
            GITHUB_RUN_ID="31345686688",
        ).strip()
        self.assertIn("END", line)
        self.assertNotIn("DONE", line)
        self.assertEqual(runners.job_ref(line), runners.JobRef("workspaces", "31345686688", 1))

    def test_a_rerun_records_which_attempt_it_was(self) -> None:
        line = self.fire(
            GITHUB_REPOSITORY="fairchild/workspaces",
            GITHUB_JOB="build",
            GITHUB_WORKFLOW="Release",
            GITHUB_REF_NAME="v0.24.0",
            GITHUB_RUN_ID="31345686688",
            GITHUB_RUN_ATTEMPT="2",
        ).strip()
        ref = runners.job_ref(line)
        assert ref is not None
        self.assertEqual(ref.attempt, 2)

    def test_first_attempt_stays_unadorned(self) -> None:
        line = self.fire(
            GITHUB_REPOSITORY="fairchild/workspaces",
            GITHUB_JOB="build",
            GITHUB_WORKFLOW="Release",
            GITHUB_REF_NAME="main",
            GITHUB_RUN_ID="1",
            GITHUB_RUN_ATTEMPT="1",
        )
        self.assertNotIn("attempt=", line)

    def test_a_job_with_no_run_id_still_logs_and_still_exits_clean(self) -> None:
        # A hook that exits non-zero fails the CI job it is only observing, so
        # missing environment degrades the line rather than the run.
        line = self.fire().strip()
        self.assertIn("END", line)
        self.assertIsNone(runners.job_ref(line))

    def test_line_stays_parseable_when_the_ref_is_hostile(self) -> None:
        line = self.fire(
            GITHUB_REPOSITORY="fairchild/workspaces",
            GITHUB_JOB="build",
            GITHUB_WORKFLOW="Release",
            GITHUB_REF_NAME='we|ird"ref',
            GITHUB_RUN_ID="99",
        ).strip()
        self.assertNotIn("|", line)
        self.assertEqual(runners.job_ref(line), runners.JobRef("workspaces", "99", 1))


class FormattingTests(unittest.TestCase):
    def test_unknown_timestamp_renders_as_never_not_as_now(self) -> None:
        self.assertEqual(runners.ago(None), "never")

    def test_byte_sizes_stay_readable_at_gigabyte_scale(self) -> None:
        self.assertEqual(runners.human_bytes(0), "0B")
        self.assertEqual(runners.human_bytes(2 * 1024**3), "2.0G")


if __name__ == "__main__":
    unittest.main()
