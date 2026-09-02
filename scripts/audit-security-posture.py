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
# Cloudflare would hang a release preflight rather than report on one.
D1_QUERY_TIMEOUT_SECONDS = 60
# The one SQL failure that is an answer rather than an obstacle: a database that has
# never had a migration applied has no `d1_migrations` table for the query to read.
# Anchored on a word boundary so a differently-named missing table (`d1_migrations_v2`)
# still raises instead of being read as "zero applied".
D1_MISSING_MIGRATIONS_TABLE = re.compile(r"no such table:\s*d1_migrations\b")


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
    """A wrangler environment and the migration-bearing D1 database it binds."""

    name: str
    database_name: str
    migrations_dir: str


def d1_environments(config: dict[str, object]) -> list[D1Environment]:
    """Every environment in a wrangler config that binds a D1 database with migrations.

    Read out of the config rather than listed here. A hardcoded list is how an
    environment goes unchecked — preview was behind too, and nothing said so — and
    this file has already been bitten once by an expectation that outlived what it
    named (see `self_hosted_lanes`).

    The top-level tables are wrangler's default environment; `[env.<name>]` adds the
    rest.
    """
    sections: dict[str, object] = {"production": config}
    named = config.get("env")
    if isinstance(named, dict):
        sections.update(named)

    environments: list[D1Environment] = []
    for name, section in sorted(sections.items()):
        if not isinstance(section, dict):
            continue
        databases = section.get("d1_databases")
        if not isinstance(databases, list):
            continue
        for database in databases:
            if not isinstance(database, dict):
                continue
            database_name = database.get("database_name")
            migrations_dir = database.get("migrations_dir")
            if database_name and migrations_dir:
                environments.append(
                    D1Environment(str(name), str(database_name), str(migrations_dir))
                )
    return environments


def applied_d1_migrations(environment: D1Environment, service_dir: Path) -> set[str]:
    """Migration names `d1_migrations` records for a live database.

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
    result = subprocess.run(
        [
            "wrangler",
            "d1",
            "execute",
            environment.database_name,
            "--remote",
            "--json",
            "--command",
            "SELECT name FROM d1_migrations ORDER BY name",
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
        # A database that has never had a migration applied has no `d1_migrations`
        # table to read. That is maximal drift — every migration in the repo is
        # pending — but treated as an unreadable answer it becomes a warn, and
        # `--strict` does not fail on warns. A freshly recreated database would then
        # report *softer* than one missing a single migration, which inverts the
        # check. Zero applied is the honest reading, and the pending-fail path below
        # already handles it.
        #
        # Both streams are searched, and neither is privileged. Wrangler writes
        # unrelated chatter to stderr routinely — an unwritable debug log is enough —
        # so reading whichever stream is non-empty would make the paragraph above
        # conditional on wrangler happening to be quiet, and the inversion would
        # return whenever it was not.
        if D1_MISSING_MIGRATIONS_TABLE.search(result.stdout) or D1_MISSING_MIGRATIONS_TABLE.search(
            result.stderr
        ):
            return set()
        detail = result.stderr.strip() or result.stdout.strip() or "wrangler failed"
        raise RuntimeError(detail)

    payload = json.loads(result.stdout)
    if not isinstance(payload, list):
        raise RuntimeError("unexpected wrangler output shape")
    names: set[str] = set()
    for statement in payload:
        if not isinstance(statement, dict):
            continue
        for row in statement.get("results") or []:
            if isinstance(row, dict) and row.get("name"):
                names.add(str(row["name"]))
    return names


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

        if not shutil.which("wrangler"):
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
    migrations_path = service_dir / environment.migrations_dir
    on_disk = sorted(path.name for path in migrations_path.glob("*.sql"))
    if not on_disk:
        return Check("warn", name, f"no .sql files under {environment.migrations_dir}")

    try:
        applied = applied_d1_migrations(environment, service_dir)
    except (
        RuntimeError,
        OSError,
        json.JSONDecodeError,
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
        checks.extend(d1_migration_checks())

    print_checks(checks)
    failed = any(check.status == "fail" for check in checks)
    return 1 if args.strict and failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
