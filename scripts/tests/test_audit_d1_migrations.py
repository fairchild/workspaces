#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Tests for the D1 migration-drift check in audit-security-posture.py.

Intent: this check exists because a migration merged and was never applied, and
production went a month without the table it creates (#1309). Every layer that
described the table was green — the schema helper creates it, the tests stub the
database, the contract documents it — so the only thing that could have caught it
was asking a live environment, and nothing did.

Two properties therefore matter more than the happy path, and both are covered
below: the repo being ahead has to FAIL, and being unable to reach an environment
has to WARN rather than PASS. A check that reports "healthy" when it could not look
is the original defect wearing a different hat.

The live query is stubbed here. The real one is exercised against production and
preview in the PR evidence; these cases pin the logic that reads its answer.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
import unittest.mock
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "audit-security-posture.py"

spec = importlib.util.spec_from_file_location("audit_security_posture", SCRIPT_PATH)
assert spec and spec.loader
audit = importlib.util.module_from_spec(spec)
sys.modules["audit_security_posture"] = audit
spec.loader.exec_module(audit)


WRANGLER_TOML = """\
    name = "feedback-store"

    [[d1_databases]]
    binding = "FEEDBACK_DB"
    database_name = "workspaces-feedback"
    database_id = "9973e814-8556-429e-88c3-391a722b453d"
    migrations_dir = "migrations"

    [env.preview]
    name = "feedback-store-preview"

    [[env.preview.d1_databases]]
    binding = "FEEDBACK_DB"
    database_name = "workspaces-feedback-preview"
    database_id = "9ceb2bfb-8cb3-46aa-afe5-b0a5c5f228d6"
    migrations_dir = "migrations"
"""


@contextlib.contextmanager
def tempdir():
    with tempfile.TemporaryDirectory() as name:
        yield Path(name)


def service_dir(tmp: Path, *migrations: str, toml: str = WRANGLER_TOML) -> Path:
    (tmp / "wrangler.toml").write_text(textwrap.dedent(toml), encoding="utf-8")
    migrations_dir = tmp / "migrations"
    migrations_dir.mkdir(exist_ok=True)
    for name in migrations:
        (migrations_dir / name).write_text("-- test\n", encoding="utf-8")
    return tmp


def environment(name: str = "production", database: str = "workspaces-feedback"):
    return audit.D1Environment(name=name, database_name=database, migrations_dir="migrations")


class FreshDatabaseTests(unittest.TestCase):
    """A database with no migrations at all must be the loudest case, not the quietest.

    It has no `d1_migrations` table, so the query fails — and read as a failure it
    becomes a warn, which `--strict` does not fail on. That would make a freshly
    recreated database report *softer* than one missing a single migration, inverting
    the check. "No such table" is not unable-to-look; it is looked, and the answer is
    zero.
    """

    # Wrangler's real output for this case, captured from a live D1 database: SQL
    # errors come back as JSON on stdout with a non-zero exit, so they arrive through
    # the same channel as the errors that genuinely mean "could not read".
    NO_TABLE_STDOUT = json.dumps(
        {
            "error": {
                "text": "A request to the Cloudflare API (/accounts/…/query) failed.",
                "notes": [{"text": "no such table: d1_migrations: SQLITE_ERROR [code: 7500]"}],
                "kind": "error",
                "name": "APIError",
                "code": 7500,
            }
        }
    )

    def stub_wrangler(self, stdout: str, returncode: int = 1, stderr: str = "") -> None:
        def fake_run(*args, **kwargs):  # noqa: ARG001
            return subprocess.CompletedProcess(
                args=[], returncode=returncode, stdout=stdout, stderr=stderr
            )

        patcher = unittest.mock.patch.object(audit.subprocess, "run", fake_run)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_database_with_no_migrations_table_reads_as_zero_applied(self) -> None:
        self.stub_wrangler(self.NO_TABLE_STDOUT)

        with tempdir() as tmp:
            applied = audit.applied_d1_migrations(environment(), service_dir(tmp))

        self.assertEqual(applied, set())

    def test_a_fresh_database_fails_rather_than_warns(self) -> None:
        """The end-to-end verdict: every migration pending is a FAIL, not a WARN."""
        self.stub_wrangler(self.NO_TABLE_STDOUT)

        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql", "0002_feedback_audit.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "fail")
        self.assertIn("0001_feedback.sql", check.detail)
        self.assertIn("0002_feedback_audit.sql", check.detail)

    def test_a_differently_named_missing_table_still_warns(self) -> None:
        """Only `d1_migrations` itself means zero applied.

        Any other missing table is a query that could not be answered, and swallowing
        it as "zero" would report drift that was never measured.
        """
        stdout = self.NO_TABLE_STDOUT.replace("d1_migrations:", "d1_migrations_v2:")
        self.stub_wrangler(stdout)

        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")

    # Wrangler writes unrelated chatter to stderr routinely — an unwritable debug log
    # is enough, and that is what the machine reviewing this PR actually produced. The
    # SQL answer is still on stdout.
    NOISY_STDERR = (
        "\n\U0001f6a8  Wrangler could not write to its debug log file at "
        "/var/folders/xx/wrangler-debug.log\n"
    )

    def test_the_missing_table_is_seen_through_noise_on_stderr(self) -> None:
        """The answer is on stdout, so a non-empty stderr must not hide it.

        Reading only whichever stream is non-empty makes the fix above conditional on
        wrangler happening to be quiet, and it is not reliably quiet.
        """
        self.stub_wrangler(self.NO_TABLE_STDOUT, stderr=self.NOISY_STDERR)

        with tempdir() as tmp:
            applied = audit.applied_d1_migrations(environment(), service_dir(tmp))

        self.assertEqual(applied, set())

    def test_a_fresh_database_fails_even_when_wrangler_writes_to_stderr(self) -> None:
        """The end-to-end shape of the regression: `warn` here means `--strict` exits 0."""
        self.stub_wrangler(self.NO_TABLE_STDOUT, stderr=self.NOISY_STDERR)

        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql", "0002_feedback_audit.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "fail")
        self.assertIn("0002_feedback_audit.sql", check.detail)

    def test_the_missing_table_is_seen_when_it_arrives_on_stderr(self) -> None:
        """Neither stream is privileged: the error can land on either one."""
        self.stub_wrangler("", stderr="no such table: d1_migrations: SQLITE_ERROR")

        with tempdir() as tmp:
            applied = audit.applied_d1_migrations(environment(), service_dir(tmp))

        self.assertEqual(applied, set())

    def test_a_genuine_failure_still_warns(self) -> None:
        self.stub_wrangler(json.dumps({"error": {"text": "Authentication error [code: 10000]"}}))

        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")


class D1AddressingTests(unittest.TestCase):
    """Why the query is aimed at the database name.

    `database_id` would be the stronger identifier — it survives a dashboard rename
    the config has not caught up with, where the name reads as "database not found"
    and lands in the soft warn bucket. It is not available: `wrangler d1 execute`
    takes "the name or binding of the DB" and rejects a uuid ("Couldn't find DB with
    name '<uuid>'"), verified against a live database. The binding would need `--env`
    and so reintroduces the environment coupling name-addressing avoids.
    """

    def test_the_query_is_addressed_by_database_name(self) -> None:
        captured: dict[str, object] = {}

        def fake_run(args, **kwargs):  # noqa: ARG001
            captured["args"] = args
            return subprocess.CompletedProcess(args=args, returncode=0, stdout="[]", stderr="")

        with unittest.mock.patch.object(audit.subprocess, "run", fake_run):
            with tempdir() as tmp:
                audit.applied_d1_migrations(environment(), service_dir(tmp))

        args = captured["args"]
        self.assertIn("workspaces-feedback", args)
        self.assertEqual(args[args.index("execute") + 1], "workspaces-feedback")


class D1EnvironmentDiscoveryTests(unittest.TestCase):
    """Environments are read out of the config, not listed in the script.

    Preview was behind too, and nothing said so. A hardcoded list is how the second
    environment goes unwatched.
    """

    def test_both_the_default_and_named_environments_are_found(self) -> None:
        import tomllib

        found = audit.d1_environments(tomllib.loads(textwrap.dedent(WRANGLER_TOML)))

        self.assertEqual(
            [(env.name, env.database_name) for env in found],
            [
                ("preview", "workspaces-feedback-preview"),
                ("production", "workspaces-feedback"),
            ],
        )

    def test_a_binding_without_migrations_is_not_watched(self) -> None:
        """`migrations_dir` is what makes a database one this check has an opinion about."""
        import tomllib

        toml = """\
            name = "svc"

            [[d1_databases]]
            binding = "DB"
            database_name = "no-migrations"
        """
        self.assertEqual(audit.d1_environments(tomllib.loads(textwrap.dedent(toml))), [])

    def test_a_config_with_no_d1_at_all_yields_nothing(self) -> None:
        import tomllib

        self.assertEqual(audit.d1_environments(tomllib.loads('name = "svc"\n')), [])


class D1DriftVerdictTests(unittest.TestCase):
    def setUp(self) -> None:
        self._real = audit.applied_d1_migrations
        self.addCleanup(setattr, audit, "applied_d1_migrations", self._real)

    def stub_applied(self, applied: set[str] | Exception) -> None:
        def fake(environment, service_dir):  # noqa: ARG001 - signature parity
            if isinstance(applied, Exception):
                raise applied
            return applied

        audit.applied_d1_migrations = fake

    def test_a_migration_in_the_repo_but_not_applied_fails(self) -> None:
        """The reported incident: 0002 merged, never applied, table missing for a month."""
        self.stub_applied({"0001_feedback.sql"})
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql", "0002_feedback_audit.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "fail")
        self.assertIn("0002_feedback_audit.sql", check.detail)

    def test_everything_applied_passes(self) -> None:
        self.stub_applied({"0001_feedback.sql", "0002_feedback_audit.sql"})
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql", "0002_feedback_audit.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "pass")

    def test_an_unreachable_environment_warns_rather_than_passes(self) -> None:
        """The property that matters most.

        Reporting "healthy" when the live state could not be read would reproduce
        exactly the blindness this check was written to remove — with the added cost
        of looking like it had been checked.
        """
        self.stub_applied(RuntimeError("not authenticated"))
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")
        self.assertIn("not authenticated", check.detail)

    def test_a_query_timeout_warns_rather_than_passes(self) -> None:
        self.stub_applied(subprocess.TimeoutExpired(cmd="wrangler", timeout=60))
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")

    def test_unparseable_wrangler_output_warns_rather_than_passes(self) -> None:
        self.stub_applied(json.JSONDecodeError("bad", "", 0))
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")

    def test_a_migration_applied_but_gone_from_the_repo_warns(self) -> None:
        """Not the reported failure, and not necessarily wrong — but the directory no
        longer describes the database, which is worth saying without failing a release."""
        self.stub_applied({"0001_feedback.sql", "0002_feedback_audit.sql"})
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")
        self.assertIn("0002_feedback_audit.sql", check.detail)

    def test_an_empty_migrations_directory_warns(self) -> None:
        """Nothing on disk means nothing to compare, which is not the same as agreement."""
        self.stub_applied(set())
        with tempdir() as tmp:
            root = service_dir(tmp)
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")


class LocalOnlyTests(unittest.TestCase):
    """`--local-only` is documented as the offline command; it must stay offline.

    `security-critical-path.md` publishes `--local-only --strict`, so a network check
    that ignored the flag would turn a documented offline command into one that hangs
    or fails on a machine with no credentials.
    """

    def test_local_only_skips_the_d1_checks(self) -> None:
        called = False

        def fake(*args, **kwargs):  # noqa: ARG001
            nonlocal called
            called = True
            return []

        real = audit.d1_migration_checks
        audit.d1_migration_checks = fake
        self.addCleanup(setattr, audit, "d1_migration_checks", real)

        with contextlib.redirect_stdout(io.StringIO()):
            audit.main(["--local-only"])

        self.assertFalse(called)


if __name__ == "__main__":
    unittest.main()
