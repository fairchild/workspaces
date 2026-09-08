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


@contextlib.contextmanager
def no_remote_audit():
    """Silence the GitHub half of `main()` so a test of the D1 half stays offline.

    These tests are network-free by design; letting `main()` reach for `gh` would make
    them slow, flaky, and dependent on the runner's credentials.
    """
    with unittest.mock.patch.object(audit, "remote_checks", lambda repo: []):  # noqa: ARG005
        yield


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


class WranglerPayloadTests(unittest.TestCase):
    """What comes back from a *successful* query, put through the real parser.

    The verdict tests below stub `applied_d1_migrations` and inject sets the author
    chose, so they pin the comparison but never the reading. A parser that is only
    ever fed its own author's idea of the answer will certify whatever that idea is —
    the same failure mode as the stubbed database that let #1309 through.
    """

    # A real `wrangler d1 execute --json` response: a list of statement results, each
    # carrying `success`, `meta`, and the rows.
    REAL_PAYLOAD = json.dumps(
        [
            {
                "success": True,
                "meta": {"served_by": "v3-prod", "duration": 0.2, "changes": 0, "rows_read": 2},
                "results": [{"name": "0001_feedback.sql"}, {"name": "0002_feedback_audit.sql"}],
            }
        ]
    )

    def stub_wrangler(self, stdout: str) -> None:
        def fake_run(*args, **kwargs):  # noqa: ARG001
            return subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout, stderr="")

        patcher = unittest.mock.patch.object(audit.subprocess, "run", fake_run)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_real_wrangler_response_yields_its_migration_names(self) -> None:
        self.stub_wrangler(self.REAL_PAYLOAD)

        with tempdir() as tmp:
            applied = audit.applied_d1_migrations(environment(), service_dir(tmp))

        self.assertEqual(applied, {"0001_feedback.sql", "0002_feedback_audit.sql"})

    def test_a_real_response_matching_the_repo_passes_end_to_end(self) -> None:
        """The pass verdict, reached through the parser rather than around it."""
        self.stub_wrangler(self.REAL_PAYLOAD)

        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql", "0002_feedback_audit.sql")
            check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "pass")

    def test_a_query_returning_no_rows_is_zero_applied_not_an_error(self) -> None:
        self.stub_wrangler(json.dumps([{"success": True, "results": []}]))

        with tempdir() as tmp:
            applied = audit.applied_d1_migrations(environment(), service_dir(tmp))

        self.assertEqual(applied, set())


class MalformedPayloadTests(unittest.TestCase):
    """A shape the parser does not recognise is a query it could not read.

    Both wrong directions are covered. Iterating a non-list `results` used to raise an
    uncaught `TypeError` that ended the whole audit before any unrelated check was
    printed; other odd shapes used to be skipped silently, which produced an empty
    applied set — indistinguishable from a fresh database, so a parsing accident read
    as maximal drift and would fail a release.
    """

    def assert_unreadable(self, payload: object) -> None:
        with self.assertRaises(RuntimeError):
            audit.migration_names(payload)

    def test_a_non_list_payload_is_unreadable(self) -> None:
        self.assert_unreadable({"results": []})

    def test_a_non_list_results_is_unreadable_rather_than_a_crash(self) -> None:
        """`{"results": 42}` raised TypeError out of the parser and sank the run."""
        self.assert_unreadable([{"results": 42}])

    def test_a_string_results_is_unreadable_rather_than_silently_empty(self) -> None:
        self.assert_unreadable([{"results": "0001_feedback.sql"}])

    def test_a_row_that_is_not_a_named_record_is_unreadable(self) -> None:
        self.assert_unreadable([{"results": ["0001_feedback.sql"]}])
        self.assert_unreadable([{"results": [{"filename": "0001_feedback.sql"}]}])

    def test_an_unreadable_payload_warns_rather_than_failing_the_release(self) -> None:
        def fake_run(*args, **kwargs):  # noqa: ARG001
            return subprocess.CompletedProcess(
                args=[], returncode=0, stdout=json.dumps([{"results": 42}]), stderr=""
            )

        with unittest.mock.patch.object(audit.subprocess, "run", fake_run):
            with tempdir() as tmp:
                root = service_dir(tmp, "0001_feedback.sql")
                check = audit.d1_environment_check(environment(), root)

        self.assertEqual(check.status, "warn")

    def test_the_audit_survives_a_d1_check_that_raises(self) -> None:
        """One check must not be able to end the run before the others are printed."""

        def explode():
            raise TypeError("something unanticipated")

        real = audit.d1_migration_checks
        audit.d1_migration_checks = explode
        self.addCleanup(setattr, audit, "d1_migration_checks", real)

        captured = io.StringIO()
        with no_remote_audit(), contextlib.redirect_stdout(captured):
            exit_code = audit.main(["--repo", "fairchild/workspaces", "--strict"])

        self.assertIn("D1 migration drift", captured.getvalue())
        self.assertIn("something unanticipated", captured.getvalue())
        self.assertEqual(exit_code, 0)


class MissingTableMatchTests(unittest.TestCase):
    """Which "no such table" messages are this table's, exactly.

    The name is cut out of the message and compared for equality. Matching the name
    *inside* the message needs a character-class boundary, and a boundary has to guess
    which characters continue an identifier — a guess wrangler's quoting makes wrong
    in both directions.
    """

    def note(self, text: str) -> str:
        """Wrangler's real error envelope: JSON on stdout, message in a note."""
        return json.dumps({"error": {"text": "API failed.", "notes": [{"text": text}]}})

    def assert_missing(self, message: str, table: str, expected: bool) -> None:
        texts = audit.error_texts(self.note(message), "")
        self.assertEqual(audit.reports_missing_table(texts, table), expected)

    def test_the_real_d1_message_is_this_table(self) -> None:
        self.assert_missing(
            "no such table: d1_migrations: SQLITE_ERROR [code: 7500]", "d1_migrations", True
        )

    def test_a_neighbouring_table_is_not_this_one(self) -> None:
        for other in ("d1_migrations_v2", "d1_migrations-v2", "d1_migrations.v2", "d1_migrations+v2"):
            with self.subTest(other=other):
                self.assert_missing(
                    f"no such table: {other}: SQLITE_ERROR [code: 7500]", "d1_migrations", False
                )

    def test_a_name_ending_in_punctuation_is_still_matched(self) -> None:
        """A word boundary would demand a word character the message does not have."""
        self.assert_missing(
            "no such table: schema-history-: SQLITE_ERROR [code: 7500]", "schema-history-", True
        )

    def test_a_quoted_name_survives_wranglers_json_escaping(self) -> None:
        """The name arrives escaped in the raw bytes; the comparison happens decoded.

        Searching the serialized JSON for an unescaped `a"b` never matches, so the
        missing table falls back to a warn and `--strict` exits zero on maximal drift.
        """
        raw = self.note('no such table: a"b: SQLITE_ERROR [code: 7500]')
        self.assertIn(r"a\"b", raw)  # the escaping that defeats a raw search
        self.assert_missing('no such table: a"b: SQLITE_ERROR [code: 7500]', 'a"b', True)

    def test_a_backslash_in_the_name_survives_too(self) -> None:
        self.assert_missing(
            "no such table: a\\b: SQLITE_ERROR [code: 7500]", "a\\b", True
        )

    def test_a_table_named_after_the_delimiter_still_matches(self) -> None:
        """Cutting the message at the first `: SQLITE_ERROR` truncates such a name.

        The configured table would then never equal what was extracted, and maximal
        drift would report as a warn again — the whole bug, one delimiter down.
        """
        self.assert_missing(
            "no such table: a: SQLITE_ERROR: SQLITE_ERROR [code: 7500]", "a: SQLITE_ERROR", True
        )

    def test_a_table_name_beginning_with_a_space_still_matches(self) -> None:
        """SQLite writes one space after the colon; the rest of it belongs to the name.

        Consuming the whitespace greedily eats the name's own leading space, and the
        configured table never matches its own error.
        """
        self.assert_missing("no such table:  a: SQLITE_ERROR [code: 7500]", " a", True)

    def test_a_message_on_a_non_json_stream_still_matches(self) -> None:
        texts = audit.error_texts("", "no such table: d1_migrations")
        self.assertTrue(audit.reports_missing_table(texts, "d1_migrations"))


class RepoMigrationsTests(unittest.TestCase):
    """`repo_migrations` under the flat layout every service in `D1_SERVICE_DIRS` uses.

    #1533 removed `migrations_pattern` support (a nested layout with a wrangler-glob
    override) once it proved unreachable from this repo's own `wrangler.toml` files;
    re-add it, with its original tests, alongside the service that needs it.
    """

    def test_bare_filenames_are_the_migration_names(self) -> None:
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql", "0002_feedback_audit.sql")
            found = audit.repo_migrations(environment(), root)

        self.assertEqual(found, ["0001_feedback.sql", "0002_feedback_audit.sql"])

    def test_a_dotfile_is_not_a_migration(self) -> None:
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            (root / "migrations" / ".hidden.sql").write_text("-- test\n", encoding="utf-8")

            found = audit.repo_migrations(environment(), root)

        self.assertEqual(found, ["0001_feedback.sql"])

    def test_a_symlinked_migration_is_not_one(self) -> None:
        """Wrangler walks with `Dirent.isFile()`, false for a symlink however it resolves.

        Counting one would report a migration as pending that wrangler will never
        apply, failing a release over a file it does not see.
        """
        with tempdir() as tmp:
            root = service_dir(tmp, "0001_feedback.sql")
            (tmp / "elsewhere.sql").write_text("-- test\n", encoding="utf-8")
            (root / "migrations" / "0002_linked.sql").symlink_to(tmp / "elsewhere.sql")

            found = audit.repo_migrations(environment(), root)

        self.assertEqual(found, ["0001_feedback.sql"])


class WranglerResolutionTests(unittest.TestCase):
    """The service's pinned wrangler outranks whatever is on PATH.

    `infra/feedback-store/package-lock.json` pins a version; a global install can be
    older and answer differently, so preferring PATH lets the operator's machine
    decide what the audit means.
    """

    def test_the_service_local_wrangler_wins(self) -> None:
        with tempdir() as tmp:
            local = tmp / "node_modules" / ".bin"
            local.mkdir(parents=True)
            (local / "wrangler").write_text("#!/bin/sh\n", encoding="utf-8")

            self.assertEqual(audit.wrangler_command(tmp), str(local / "wrangler"))

    def test_path_is_the_fallback(self) -> None:
        with unittest.mock.patch.object(audit.shutil, "which", lambda name: "/usr/bin/" + name):
            with tempdir() as tmp:
                self.assertEqual(audit.wrangler_command(tmp), "/usr/bin/wrangler")

    def test_no_wrangler_anywhere_is_reported_as_such(self) -> None:
        with unittest.mock.patch.object(audit.shutil, "which", lambda name: None):  # noqa: ARG005
            with tempdir() as tmp:
                self.assertIsNone(audit.wrangler_command(tmp))

                checks = audit.d1_migration_checks((service_dir(tmp),))

        self.assertEqual([check.status for check in checks], ["warn"])
        self.assertIn("wrangler is not installed", checks[0].detail)


class SkipD1Tests(unittest.TestCase):
    """`--skip-d1` keeps the GitHub remote audit on a machine with no D1 access.

    Without it the only opt-out is `--local-only`, which gives up the whole remote
    lane to avoid one check that needs Cloudflare credentials.
    """

    def test_skip_d1_skips_only_the_d1_checks(self) -> None:
        called = False

        def fake():
            nonlocal called
            called = True
            return []

        real = audit.d1_migration_checks
        audit.d1_migration_checks = fake
        self.addCleanup(setattr, audit, "d1_migration_checks", real)

        with no_remote_audit(), contextlib.redirect_stdout(io.StringIO()):
            audit.main(["--repo", "fairchild/workspaces", "--skip-d1"])

        self.assertFalse(called)


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
        """The unnamed environment is labelled for what it is, not for what it deploys.

        It used to be called `production`, which is true of this repo and not of the
        config: wrangler's top-level tables are the default environment, and calling
        them by a guessed deployment name is what let `[env.production]` collide with
        them.
        """
        import tomllib

        found = audit.d1_environments(tomllib.loads(textwrap.dedent(WRANGLER_TOML)))

        self.assertEqual(
            [(env.name, env.database_name) for env in found],
            [
                ("top-level", "workspaces-feedback"),
                ("preview", "workspaces-feedback-preview"),
            ],
        )

    def test_a_named_production_environment_does_not_erase_the_default_one(self) -> None:
        """Wrangler's unnamed top-level environment is distinct from `[env.production]`.

        Both are legal in the same config and they can point at different databases.
        Keying the top-level one under a guessed name lets a real `[env.production]`
        overwrite it, and the default environment then gets no check and no warning —
        the exact "an environment goes unchecked" failure this function claims to avoid.
        """
        import tomllib

        toml = """\
            name = "svc"

            [[d1_databases]]
            binding = "DB"
            database_name = "default-db"
            migrations_dir = "migrations"

            [env.production]
            name = "svc-production"

            [[env.production.d1_databases]]
            binding = "DB"
            database_name = "named-prod-db"
            migrations_dir = "migrations"
        """
        found = audit.d1_environments(tomllib.loads(textwrap.dedent(toml)))

        self.assertIn(
            "default-db",
            {env.database_name for env in found},
            "the top-level environment was dropped from the audit",
        )
        self.assertEqual(len(found), 2)

    def test_a_binding_that_omits_migrations_dir_gets_wranglers_default(self) -> None:
        """Omitting the field is not opting out; wrangler defaults it to `migrations`.

        Requiring it meant a binding relying on the default had migrations this check
        never looked at — the same unwatched-environment failure as the collision
        above, reached by leaving a line out rather than by adding one.
        """
        import tomllib

        toml = """\
            name = "svc"

            [[d1_databases]]
            binding = "DB"
            database_name = "defaulted-db"
        """
        found = audit.d1_environments(tomllib.loads(textwrap.dedent(toml)))

        self.assertEqual([env.database_name for env in found], ["defaulted-db"])
        self.assertEqual([env.migrations_dir for env in found], ["migrations"])

    def test_an_empty_migrations_dir_is_the_project_root_not_the_default(self) -> None:
        """Wrangler defaults on absence, not on falseyness, and normalises `""` to `.`.

        Reading an explicit empty string as `migrations` would compare a directory the
        service does not use and pass while a root-level migration sat pending.
        """
        import tomllib

        toml = """\
            name = "svc"

            [[d1_databases]]
            binding = "DB"
            database_name = "root-db"
            migrations_dir = ""
        """
        found = audit.d1_environments(tomllib.loads(textwrap.dedent(toml)))

        self.assertEqual([env.migrations_dir for env in found], ["."])

    def test_a_trailing_slash_is_the_same_directory(self) -> None:
        import tomllib

        toml = """\
            name = "svc"

            [[d1_databases]]
            binding = "DB"
            database_name = "db"
            migrations_dir = "./migrations/"
        """
        found = audit.d1_environments(tomllib.loads(textwrap.dedent(toml)))

        self.assertEqual([env.migrations_dir for env in found], ["migrations"])

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
