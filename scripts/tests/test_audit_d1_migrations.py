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
    migrations_dir = "migrations"

    [env.preview]
    name = "feedback-store-preview"

    [[env.preview.d1_databases]]
    binding = "FEEDBACK_DB"
    database_name = "workspaces-feedback-preview"
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
