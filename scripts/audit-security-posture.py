#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Report operational security posture for release and agent automation.

Covers what CI configuration alone cannot say: which runner lanes the workflows
actually target, which secrets exist at which scope, and which D1 migrations a
live environment has actually applied.

This script is intentionally report-only by default. Use --strict when a
release checklist should fail on missing controls.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
# Lanes that were decommissioned. `tart-ui` per
# docs/decisions/perf-measurement-laptop-optin.md, `lume-macos` per the #1288
# follow-up, `signing-host` when `blue-workspaces` was deregistered on
# 2026-08-13. A workflow reaching for any of them is targeting hardware that is
# gone, so the job queues forever rather than failing.
RETIRED_RUNNER_LABELS = {"lume-macos", "signing-host", "tart-ui"}
# OS and architecture qualifiers, not lanes: they narrow which self-hosted
# machine takes the job, they do not name a purpose.
RUNNER_QUALIFIER_LABELS = {"self-hosted", "macos", "linux", "windows", "arm64", "x64", "x86"}
EXPECTED_ENVIRONMENTS = {"release", "xcode-cloud-logs"}
EXPECTED_REPO_SECRETS = {
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLOUDFLARE_ACCOUNT_ID",
    "CLOUDFLARE_API_TOKEN",
    "EVIDENCE_UPLOAD_TOKEN",
    "VERCEL_ORG_ID",
    "VERCEL_PROJECT_ID",
    "VERCEL_TOKEN",
}
LEGACY_REPO_SECRETS = {"APPLE_APP_PASSWORD"}
# Signing credentials live only on the release environment, so a job must declare
# `environment: release` — and clear its human approval — to read them at all.
EXPECTED_ENVIRONMENT_SECRETS = {
    # Both environments hold the App Store Connect triple. They are separate
    # copies, not a shared one: release gates on human approval, while
    # xcode-cloud-logs gates only on a branch policy, because fetching build
    # logs should not need an approval.
    "xcode-cloud-logs": {
        "APPLE_API_ISSUER_ID",
        "APPLE_API_KEY_BASE64",
        "APPLE_API_KEY_ID",
    },
    "release": {
        "APPLE_API_ISSUER_ID",
        "APPLE_API_KEY_BASE64",
        "APPLE_API_KEY_ID",
        "APPLE_DEVELOPER_ID_CERT_BASE64",
        "APPLE_DEVELOPER_ID_CERT_PASSWORD",
        "APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64",
        "SPARKLE_PRIVATE_KEY",
    },
}
# An environment secret shadows the repository secret of the same name, including
# when the environment copy is empty — that is how two empty values hid two
# working ones during the v0.24.0 arc. Emptiness is invisible from outside (the
# API exposes only name and timestamps), so the reachable signal is the shadowing
# itself. No name is dual-scoped by design any more; every credential the
# release and log lanes use lives on an environment only.
DUAL_SCOPE_EXPECTED: set[str] = set()

# Services whose D1 migrations are compared against what each environment has
# actually applied. Scoped to the one service that has the problem; a second
# entry is cheap when a second case is real.
D1_SERVICE_DIRS = (REPO_ROOT / "infra" / "feedback-store",)
# Bounded because this is the check that leaves the machine. An unbounded wait on
# Cloudflare would hang a release preflight rather than report on one. Per
# environment, not per run: environments are queried in sequence, so a service with
# two of them can wait twice this long.
D1_QUERY_TIMEOUT_SECONDS = 60
# Wrangler's defaults for the migration settings a binding may override.
D1_DEFAULT_MIGRATIONS_TABLE = "d1_migrations"
D1_DEFAULT_MIGRATIONS_DIR = "migrations"
# Glob syntax minimatch implements and `Path.glob` does not. A pattern using any of
# it would silently match a different set of files than wrangler matches, so it is
# reported rather than guessed at.
D1_UNSUPPORTED_GLOB = re.compile(r"[{}]|[!?+*@]\(")
# Wrangler's unnamed top-level tables are an environment in their own right, distinct
# from any `[env.<name>]`. Naming it for what it is rather than for what this repo
# happens to deploy there keeps a real `[env.production]` from colliding with it.
D1_DEFAULT_ENVIRONMENT = "top-level"


D1_NO_SUCH_TABLE = re.compile(r"no such table:\s*")
# D1 appends this to SQLite's message, so it is where the reported name ends.
D1_SQLITE_ERROR_SUFFIX = re.compile(r":\s*SQLITE_ERROR\b")


def error_texts(*streams: str) -> list[str]:
    """Every message inside wrangler's output, JSON-decoded where it is JSON.

    Wrangler reports SQL errors as JSON, so a table name in the message arrives
    escaped: a table named `a"b` reads as `a\\"b` in the raw bytes and would never
    equal the name we asked for. Decoding first compares like with like. The raw
    stream is kept too, for output that is not JSON at all.
    """
    texts: list[str] = []
    for stream in streams:
        if not stream:
            continue
        texts.append(stream)
        try:
            payload = json.loads(stream)
        except ValueError:
            continue
        texts.extend(nested_strings(payload))
    return texts


def nested_strings(payload: object) -> list[str]:
    if isinstance(payload, str):
        return [payload]
    if isinstance(payload, list):
        return [text for item in payload for text in nested_strings(item)]
    if isinstance(payload, dict):
        return [text for item in payload.values() for text in nested_strings(item)]
    return []


def reports_missing_table(texts: list[str], table: str) -> bool:
    """Whether any message says *this* table does not exist.

    The configured name is checked at the position it must occupy and what follows it
    must be the end of the message or D1's own suffix. A character-class boundary
    would have to guess which characters continue an identifier, and wrangler quotes
    the name so it may contain any of them: `d1_migrations-v2` and `d1_migrations.v2`
    are different tables that a boundary reads as this one, and a name ending in
    punctuation is one this table's own error would miss. Anchoring does not guess.

    A missing table is the one SQL failure that is an answer rather than an obstacle:
    a database that has never had a migration applied has no migrations table, which
    is maximal drift rather than an unreadable result.
    """
    for text in texts:
        for match in D1_NO_SUCH_TABLE.finditer(text):
            reported = text[match.end() :]
            if not reported.startswith(table):
                continue
            # The name is checked where it must be, and what follows must be the end of
            # the message or D1's own suffix. Cutting the message at the first
            # `: SQLITE_ERROR` instead would truncate a table whose name contains that
            # text, and the configured name would never match its own error.
            tail = reported[len(table) :]
            if not tail.strip() or D1_SQLITE_ERROR_SUFFIX.match(tail):
                return True
    return False


def quote_identifier(name: str) -> str:
    """A SQLite identifier, quoted the way wrangler quotes it.

    Wrangler writes the migrations table name into its own queries this way, so a
    binding may legally name a table something a bare identifier could not be.
    Doubling the quote is what makes the name data rather than syntax.
    """
    escaped = name.replace('"', '""')
    return f'"{escaped}"'


@dataclass(frozen=True)
class Check:
    status: str
    name: str
    detail: str


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def gh_json(args: list[str]) -> object:
    result = run(["gh", *args])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "gh command failed")
    return json.loads(result.stdout)


@dataclass(frozen=True)
class JobTarget:
    workflow: str
    job: str
    labels: tuple[str, ...]
    dynamic: bool

    @property
    def self_hosted(self) -> bool:
        return "self-hosted" in {label.lower() for label in self.labels}

    @property
    def lanes(self) -> list[str]:
        """Purpose labels, with OS/arch qualifiers dropped.

        A target of `[self-hosted, macOS, ARM64]` names no lane but is still
        self-hosted, so it reports under its own name rather than disappearing
        once the qualifiers are filtered out.
        """
        named = [label for label in self.labels if label.lower() not in RUNNER_QUALIFIER_LABELS]
        return named or ["self-hosted (unqualified)"]


def workflow_paths(workflow_dir: Path) -> list[Path]:
    return sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")])


def job_targets(workflow_dir: Path) -> list[JobTarget]:
    """Every job's `runs-on`, parsed as YAML rather than matched as text.

    `runs-on` accepts a scalar, a sequence, a `group`/`labels` mapping, or an
    expression, and any of them can carry comments or quoting. A line matcher
    reads several of those as "nothing self-hosted here" — the exact false PASS
    this check exists to prevent — so the structure is parsed, and anything that
    only resolves at run time is marked `dynamic` instead of assumed empty.
    """
    targets: list[JobTarget] = []
    for path in workflow_paths(workflow_dir):
        try:
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError:
            targets.append(JobTarget(path.name, "<unparseable>", (), True))
            continue
        if not isinstance(document, dict):
            continue
        jobs = document.get("jobs")
        if not isinstance(jobs, dict):
            continue
        for name, job in jobs.items():
            if not isinstance(job, dict) or "runs-on" not in job:
                continue  # reusable-workflow call: `uses:`, no runner of its own
            targets.append(_target(path.name, str(name), job["runs-on"]))
    return targets


def _target(workflow: str, job: str, runs_on: object) -> JobTarget:
    if isinstance(runs_on, dict):  # {group: ..., labels: [...]}
        raw = [runs_on.get("group"), *(runs_on.get("labels") or [])]
    elif isinstance(runs_on, (list, tuple)):
        raw = list(runs_on)
    else:
        raw = [runs_on]
    labels = [str(item) for item in raw if item is not None]
    return JobTarget(workflow, job, tuple(labels), any("${{" in label for label in labels))


def self_hosted_lanes(workflow_dir: Path) -> dict[str, set[str]]:
    """Self-hosted lane label -> workflows targeting it, read from the workflows.

    Derived rather than hardcoded: the previous fixed expectation outlived the
    lanes it named and kept asserting a release runner the workflows had already
    stopped using.
    """
    lanes: dict[str, set[str]] = {}
    for target in job_targets(workflow_dir):
        if not target.self_hosted:
            continue
        for lane in target.lanes:
            lanes.setdefault(lane, set()).add(target.workflow)
    return lanes


def local_workflow_checks() -> list[Check]:
    checks: list[Check] = []
    workflow_dir = REPO_ROOT / ".github/workflows"
    workflows = sorted(workflow_dir.glob("*.yml"))
    pull_request_target = [
        path.name for path in workflows if "pull_request_target" in path.read_text(encoding="utf-8")
    ]
    checks.append(
        Check(
            "fail" if pull_request_target else "pass",
            "no pull_request_target workflows",
            ", ".join(pull_request_target) if pull_request_target else "none found",
        )
    )

    release = (workflow_dir / "release.yml").read_text(encoding="utf-8")
    checks.append(
        Check(
            "pass" if "environment: release" in release else "fail",
            "release workflow uses protected environment",
            "release environment referenced" if "environment: release" in release else "missing",
        )
    )
    targets = job_targets(workflow_dir)

    # Every release job, not "some job somewhere is hosted": reverting only the
    # signing job to self-hosted leaves the other jobs hosted, so a check that
    # merely finds one hosted `runs-on` passes the regression it guards against.
    release_self_hosted = sorted(
        f"{target.job} ({', '.join(target.labels)})"
        for target in targets
        if target.workflow == "release.yml" and target.self_hosted
    )
    checks.append(
        Check(
            "fail" if release_self_hosted else "pass",
            "every release job runs on a hosted image",
            "; ".join(release_self_hosted)
            if release_self_hosted
            else "no release job targets a self-hosted runner",
        )
    )

    retired = sorted(
        f"{target.workflow}:{target.job} ({', '.join(target.labels)})"
        for target in targets
        if {label.lower() for label in target.labels} & RETIRED_RUNNER_LABELS
    )
    checks.append(
        Check(
            "fail" if retired else "pass",
            "no workflow targets a retired runner lane",
            "; ".join(retired) if retired else "none targeted",
        )
    )

    # Separate check, because "found no retired lane" and "could read every
    # target" are different claims and a run-time expression only supports the
    # first. Folding them together reports a clean bill for a lane the audit
    # never actually saw.
    unresolved = sorted(
        f"{target.workflow}:{target.job}" for target in targets if target.dynamic
    )
    checks.append(
        Check(
            "fail" if unresolved else "pass",
            "every runs-on is statically verifiable",
            "resolves only at run time: " + ", ".join(unresolved)
            if unresolved
            else "no expression-valued runs-on",
        )
    )

    return checks


def resolve_repo(explicit: str | None) -> str:
    if explicit:
        return explicit
    data = gh_json(["repo", "view", "--json", "nameWithOwner"])
    repo = str((data if isinstance(data, dict) else {}).get("nameWithOwner", ""))
    if not repo:
        raise RuntimeError("could not resolve repository; pass --repo owner/name")
    return repo


def remote_environment_checks(repo: str) -> list[Check]:
    checks: list[Check] = []
    for environment in sorted(EXPECTED_ENVIRONMENTS):
        try:
            data = gh_json(["api", f"repos/{repo}/environments/{environment}"])
        except RuntimeError as error:
            checks.append(Check("fail", f"environment {environment}", str(error)))
            continue
        rules = data.get("protection_rules") if isinstance(data, dict) else None
        protected = isinstance(rules, list) and len(rules) > 0
        checks.append(
            Check(
                "pass" if protected else "warn",
                f"environment {environment}",
                "has protection rules" if protected else "exists but has no protection rules",
            )
        )
    return checks


def remote_runner_checks(repo: str) -> list[Check]:
    data = gh_json(["api", f"repos/{repo}/actions/runners?per_page=100"])
    runners = data.get("runners", []) if isinstance(data, dict) else []
    labels = {
        str(label.get("name"))
        for runner in runners
        if isinstance(runner, dict)
        for label in runner.get("labels", [])
        if isinstance(label, dict) and label.get("name")
    }
    required = set(self_hosted_lanes(REPO_ROOT / ".github/workflows"))
    missing_required = sorted(required - labels)
    if not required:
        detail = (
            f"no workflow targets a self-hosted lane; {len(runners)} runner(s) still registered"
            if runners
            else "no workflow targets a self-hosted lane; none registered"
        )
        return [Check("pass", "self-hosted lanes workflows depend on", detail)]
    return [
        Check(
            "fail" if missing_required else "pass",
            "self-hosted lanes workflows depend on",
            f"missing: {', '.join(missing_required)}"
            if missing_required
            else f"present: {', '.join(sorted(required))}",
        ),
    ]


def remote_secret_checks(repo: str) -> list[Check]:
    data = gh_json(["secret", "list", "--repo", repo, "--json", "name"])
    secrets = {
        str(item.get("name"))
        for item in data
        if isinstance(item, dict) and item.get("name")
    }
    missing = sorted(EXPECTED_REPO_SECRETS - secrets)
    legacy = sorted(LEGACY_REPO_SECRETS & secrets)
    checks = [
        Check(
            "fail" if missing else "pass",
            "expected repository secrets",
            f"missing: {', '.join(missing)}" if missing else "all expected names present",
        ),
        Check(
            "warn" if legacy else "pass",
            "legacy repository secrets",
            f"remove stale names: {', '.join(legacy)}" if legacy else "none found",
        ),
    ]

    for environment, expected in sorted(EXPECTED_ENVIRONMENT_SECRETS.items()):
        env_secrets = {
            str(item.get("name"))
            for item in gh_json(
                ["secret", "list", "--repo", repo, "--env", environment, "--json", "name"]
            )
            if isinstance(item, dict) and item.get("name")
        }
        env_missing = sorted(expected - env_secrets)
        shadowed = sorted((env_secrets & secrets) - DUAL_SCOPE_EXPECTED)
        checks.append(
            Check(
                "fail" if env_missing else "pass",
                f"expected {environment} environment secrets",
                f"missing: {', '.join(env_missing)}"
                if env_missing
                else "all expected names present",
            )
        )
        checks.append(
            Check(
                "warn" if shadowed else "pass",
                f"{environment} environment shadows repository secrets",
                f"also at repository scope, so the environment copy wins silently: "
                f"{', '.join(shadowed)}"
                if shadowed
                else "no unintended dual-scoped names",
            )
        )

    return checks


@dataclass(frozen=True)
class D1Environment:
    """A wrangler environment and the migration-bearing D1 database it binds.

    `migrations_table` and `migrations_pattern` carry the binding's own overrides of
    wrangler's defaults. Assuming the defaults would make a service that sets either
    one read as maximally drifted or as having nothing to compare, which is a verdict
    about this script rather than about the database.
    """

    name: str
    database_name: str
    migrations_dir: str
    migrations_table: str = D1_DEFAULT_MIGRATIONS_TABLE
    migrations_pattern: str | None = None


def d1_environments(config: dict[str, object]) -> list[D1Environment]:
    """Every environment in a wrangler config that binds a D1 database with migrations.

    Read out of the config rather than listed here. A hardcoded list is how an
    environment goes unchecked — preview was behind too, and nothing said so — and
    this file has already been bitten once by an expectation that outlived what it
    named (see `self_hosted_lanes`).

    The top-level tables are wrangler's default environment; `[env.<name>]` adds the
    rest. They are collected as a list rather than keyed by name because the two
    namespaces can collide: `[env.production]` is legal, distinct from the top-level
    environment, and may bind a different database. Keyed, the named one would
    overwrite the default and the default would go unchecked and unreported — the
    failure this function exists to prevent, arriving from the inside.
    """
    sections: list[tuple[str, object]] = [(D1_DEFAULT_ENVIRONMENT, config)]
    named = config.get("env")
    if isinstance(named, dict):
        sections.extend(sorted(named.items()))

    environments: list[D1Environment] = []
    for name, section in sections:
        if not isinstance(section, dict):
            continue
        databases = section.get("d1_databases")
        if not isinstance(databases, list):
            continue
        for database in databases:
            if not isinstance(database, dict):
                continue
            database_name = database.get("database_name")
            if database_name:
                # `migrations_dir` is defaulted rather than required. Wrangler defaults
                # it to `migrations`, so a binding that relies on the default has
                # migrations this check would otherwise never look at — the same
                # unwatched-environment failure, reached by omitting a field.
                #
                # Defaulted the way wrangler defaults it: only an absent value, never
                # an empty one. Wrangler normalises `""` to `"."`, the project root, so
                # reading it as `migrations` would compare a directory the service does
                # not use and pass while a root-level migration sat pending.
                raw_dir = database.get("migrations_dir")
                migrations_dir = (
                    D1_DEFAULT_MIGRATIONS_DIR
                    if raw_dir is None
                    else normalize_relative_path(str(raw_dir))
                )
                # `migrations_table` is the one wrangler defaults on falseyness rather
                # than absence, so an empty name does become `d1_migrations` there.
                table = database.get("migrations_table") or D1_DEFAULT_MIGRATIONS_TABLE
                raw_pattern = database.get("migrations_pattern")
                pattern = (
                    None if raw_pattern is None else normalize_relative_path(str(raw_pattern))
                )
                environments.append(
                    D1Environment(
                        str(name),
                        str(database_name),
                        migrations_dir,
                        str(table),
                        pattern,
                    )
                )
    return environments


def normalize_relative_path(value: str) -> str:
    """Wrangler's own normalisation of a config path.

    Backslashes become forward slashes, the path is normalised, and a trailing slash
    is dropped — so `migrations/` and `./migrations` are the same directory, and `""`
    becomes `"."`, the project root.
    """
    return posixpath.normpath(value.replace("\\", "/"))


def wrangler_command(service_dir: Path) -> str | None:
    """The wrangler to run for a service, or None when there is none to run.

    The service's own install wins over PATH: `package-lock.json` pins a version and a
    global install can be older, so preferring PATH would let the operator's machine
    decide what the audit means.
    """
    local = service_dir / "node_modules" / ".bin" / "wrangler"
    if local.is_file():
        return str(local)
    return shutil.which("wrangler")


def applied_d1_migrations(environment: D1Environment, service_dir: Path) -> set[str]:
    """Migration names the binding's migrations table records for a live database.

    Addressed by `database_name` rather than by `--env`, so the lookup cannot drift
    from the binding this environment was read out of.

    Not by `database_id`, though the binding carries one and an id would survive a
    dashboard rename the config has not caught up with: `wrangler d1 execute` takes
    "the name or binding of the DB" and rejects a uuid outright ("Couldn't find DB
    with name '<uuid>'"). The remaining alternative, the binding name, would need
    `--env` to resolve and so reintroduces exactly the environment coupling this
    avoids. Name it is, by the tool's constraint rather than by preference.

    Read-only by construction: a `SELECT` is the whole query, and this script never
    applies anything — knowing a migration is pending is the gap, and applying one
    should stay a deliberate act.

    An empty set means the database answered and has applied nothing. Callers must not
    read it as "could not tell", which is what raising is for.
    """
    table = environment.migrations_table
    # Wrangler quotes the name, so almost anything is legal. A NUL cannot go through
    # argv at all, and an empty name is not a table.
    if not table or "\x00" in table:
        raise RuntimeError(f"unusable migrations_table name: {table!r}")

    result = subprocess.run(
        [
            wrangler_command(service_dir) or "wrangler",
            "d1",
            "execute",
            environment.database_name,
            "--remote",
            "--json",
            "--command",
            f"SELECT name FROM {quote_identifier(table)} ORDER BY name",
        ],
        cwd=service_dir,
        text=True,
        capture_output=True,
        check=False,
        timeout=D1_QUERY_TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        # Wrangler reports SQL errors as JSON on stdout with a non-zero exit, so the
        # one failure that is an *answer* arrives through the same channel as the
        # failures that are obstacles.
        #
        # A database that has never had a migration applied has no migrations table to
        # read. That is maximal drift — every migration in the repo is pending — but
        # treated as an unreadable answer it becomes a warn, and `--strict` does not
        # fail on warns. A freshly recreated database would then report *softer* than
        # one missing a single migration, which inverts the check. Zero applied is the
        # honest reading, and the pending-fail path below already handles it.
        #
        # Both streams are read, and neither is privileged. Wrangler writes unrelated
        # chatter to stderr routinely — an unwritable debug log is enough — so reading
        # whichever stream is non-empty would make this conditional on wrangler
        # happening to be quiet, and the inversion would return whenever it was not.
        if reports_missing_table(error_texts(result.stdout, result.stderr), table):
            return set()
        detail = result.stderr.strip() or result.stdout.strip() or "wrangler failed"
        raise RuntimeError(detail)

    return migration_names(json.loads(result.stdout))


def migration_names(payload: object) -> set[str]:
    """The migration names in a successful wrangler `--json` response.

    Every departure from the expected shape raises rather than being skipped. A shape
    this does not recognise is a query it could not read, and the caller turns that
    into a `warn`; silently dropping the rows it cannot parse would instead produce an
    empty applied set, which reads as maximal drift and fails a release on a parsing
    accident.
    """
    if not isinstance(payload, list):
        raise RuntimeError(f"unexpected wrangler output: {type(payload).__name__}, expected a list")
    names: set[str] = set()
    for statement in payload:
        if not isinstance(statement, dict):
            raise RuntimeError(f"unexpected wrangler statement: {type(statement).__name__}")
        rows = statement.get("results")
        if rows is None:
            continue
        if not isinstance(rows, list):
            raise RuntimeError(f"unexpected wrangler results: {type(rows).__name__}")
        for row in rows:
            if not isinstance(row, dict) or not row.get("name"):
                raise RuntimeError(f"unexpected wrangler row: {row!r}")
            names.add(str(row["name"]))
    return names


def repo_migrations(environment: D1Environment, service_dir: Path) -> list[str]:
    """The migration names on disk, as wrangler would record them.

    Under the default flat layout that is the filename. Under a `migrations_pattern`
    it is the path relative to `migrations_dir`, which is what wrangler writes into
    the migrations table, so the two sides of the comparison stay in the same
    vocabulary.
    """
    migrations_dir = service_dir / environment.migrations_dir
    if environment.migrations_pattern is None:
        return sorted(
            path.name
            for path in migrations_dir.glob("*.sql")
            if path.is_file() and not path.name.startswith(".")
        )

    relative_pattern = strip_dir_prefix(
        environment.migrations_pattern, environment.migrations_dir
    )
    # Wrangler matches with minimatch and this matches with `Path.glob`. They agree on
    # `*`, `?` and `**`, which is what the documented layouts use. They do not agree on
    # braces, extglobs, or a leading `!`, which minimatch reads as negating the whole
    # pattern. A pattern using any of those would quietly compare a different set of
    # files than wrangler applies, so it is reported rather than guessed at.
    if relative_pattern.startswith("!") or D1_UNSUPPORTED_GLOB.search(relative_pattern):
        raise RuntimeError(
            f"migrations_pattern {environment.migrations_pattern!r} uses glob syntax this "
            "check does not implement (negation, braces, or extglobs)"
        )
    # Minimatch runs with `dot: false`, so a dotfile is not a migration there and must
    # not be one here; `Path.glob` would otherwise report a pending migration wrangler
    # never applies.
    return sorted(
        path.relative_to(migrations_dir).as_posix()
        for path in migrations_dir.glob(relative_pattern)
        if path.is_file()
        and not any(part.startswith(".") for part in path.relative_to(migrations_dir).parts)
    )


def strip_dir_prefix(pattern: str, migrations_dir: str) -> str:
    """The pattern relative to `migrations_dir`, the way wrangler strips it.

    Wrangler requires `migrations_pattern` to start with `${migrations_dir}/` and then
    walks from that directory, so the names it records are relative to it. The one
    exception is its own: a `migrations_dir` of `.` is the project root and strips
    nothing.
    """
    if migrations_dir == ".":
        return pattern
    prefix = f"{migrations_dir}/"
    if not pattern.startswith(prefix):
        raise RuntimeError(f"migrations_pattern {pattern!r} does not start with {prefix!r}")
    return pattern[len(prefix) :]


def d1_migration_checks(service_dirs: tuple[Path, ...] = D1_SERVICE_DIRS) -> list[Check]:
    """Per environment, the repo's migrations against the ones actually applied.

    `0002_feedback_audit.sql` was merged and never applied, and production went a
    month without the table it creates (#1309). Nothing noticed, because every layer
    that described the table was green: the schema helper creates it, the tests stub
    the database, and the contract documents it. Only the live environment knew, and
    nothing asked it.

    A failure to reach an environment is a `warn`, never a `pass`. "I could not look"
    reported as healthy is the shape of the original defect, and repeating it here
    would be worse than not checking at all.
    """
    checks: list[Check] = []
    for service_dir in service_dirs:
        config_path = service_dir / "wrangler.toml"
        if not config_path.is_file():
            continue

        try:
            config = tomllib.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as error:
            checks.append(
                Check("warn", f"D1 migration drift ({service_dir.name})", f"unreadable wrangler.toml: {error}")
            )
            continue

        environments = d1_environments(config)
        if not environments:
            continue

        if wrangler_command(service_dir) is None:
            checks.append(
                Check(
                    "warn",
                    f"D1 migration drift ({service_dir.name})",
                    "wrangler is not installed, so applied migrations could not be read",
                )
            )
            continue

        for environment in environments:
            checks.append(d1_environment_check(environment, service_dir))
    return checks


def d1_environment_check(environment: D1Environment, service_dir: Path) -> Check:
    name = f"D1 migration drift ({service_dir.name}/{environment.name})"
    try:
        on_disk = repo_migrations(environment, service_dir)
    except (RuntimeError, OSError, ValueError) as error:
        return Check("warn", name, f"could not list the repo's migrations: {error}")
    if not on_disk:
        return Check("warn", name, f"no migration files under {environment.migrations_dir}")

    try:
        applied = applied_d1_migrations(environment, service_dir)
    except (
        RuntimeError,
        OSError,
        ValueError,  # json.JSONDecodeError
        subprocess.TimeoutExpired,
    ) as error:
        return Check("warn", name, f"could not read applied migrations: {error}")

    pending = [migration for migration in on_disk if migration not in applied]
    if pending:
        return Check(
            "fail",
            name,
            f"{len(pending)} migration(s) never applied to {environment.database_name}: "
            f"{', '.join(pending)}",
        )

    # Applied but no longer in the repo. Not the reported failure and not
    # necessarily wrong (a migration can be deleted after it lands everywhere), but
    # it means the directory no longer describes the database.
    unknown = sorted(applied - set(on_disk))
    if unknown:
        return Check(
            "warn",
            name,
            f"applied to {environment.database_name} but absent from "
            f"{environment.migrations_dir}: {', '.join(unknown)}",
        )

    return Check(
        "pass",
        name,
        f"{len(on_disk)} migration(s), all applied to {environment.database_name}",
    )


def remote_checks(repo: str) -> list[Check]:
    if not shutil.which("gh"):
        return [Check("warn", "GitHub remote audit", "gh CLI is not installed")]
    checks: list[Check] = []
    for collect in (
        remote_environment_checks,
        remote_runner_checks,
        remote_secret_checks,
    ):
        try:
            checks.extend(collect(repo))
        except RuntimeError as error:
            checks.append(Check("warn", collect.__name__, str(error)))
    return checks


def print_checks(checks: list[Check]) -> None:
    for check in checks:
        print(f"[{check.status.upper()}] {check.name}: {check.detail}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="GitHub repository in owner/name form.")
    parser.add_argument("--local-only", action="store_true", help="Skip gh API checks.")
    parser.add_argument(
        "--skip-d1",
        action="store_true",
        help="Skip the live D1 migration-drift checks, keeping the rest of the remote audit.",
    )
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on fail checks.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    checks = local_workflow_checks()
    if not args.local_only:
        try:
            repo = resolve_repo(args.repo)
            checks.extend(remote_checks(repo))
        except RuntimeError as error:
            checks.append(Check("warn", "GitHub remote audit", str(error)))
        # Outside the block above: reading a live database does not depend on
        # resolving the GitHub repo, and a failure to do one should not hide the other.
        #
        # `--skip-d1` exists because this is the only check needing Cloudflare
        # credentials; without it, a caller who wants the GitHub audit on a machine
        # with no D1 access has to give up the whole remote lane via `--local-only`.
        if not args.skip_d1:
            try:
                checks.extend(d1_migration_checks())
            except Exception as error:  # noqa: BLE001
                # Broad on purpose: one check must not be able to end the run before
                # the others are printed. An unanticipated failure here is reported as
                # a check that could not look, which is what every other D1 obstacle
                # reports.
                checks.append(Check("warn", "D1 migration drift", f"check failed: {error}"))

    print_checks(checks)
    failed = any(check.status == "fail" for check in checks)
    return 1 if args.strict and failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
