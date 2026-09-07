#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Bind a tested release candidate to its source and promote its existing bytes.

This replaces the release workflow's inline metadata/publication shell. GitHub
job dependencies own waiting; these commands fail closed rather than polling CI.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PLIST = "Sources/WorkspaceManager/Resources/Info.plist"
SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?")
MAX_AGE = dt.timedelta(days=7)


def run(*args: str, cwd: Path = ROOT, stdin: str | None = None) -> str:
    try:
        result = subprocess.run(args, cwd=cwd, input=stdin, text=True, capture_output=True, timeout=180)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{args[0]} {args[1]} timed out") from error
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def api(path: str, *, method: str = "GET", data: dict | None = None):
    args = ["gh", "api", path, "--method", method]
    if data is not None:
        args += ["--input", "-"]
    return json.loads(run(*args, stdin=json.dumps(data) if data is not None else None) or "null")


def optional_api(path: str):
    try:
        return api(path)
    except RuntimeError as error:
        if "HTTP 404" in str(error):
            return None
        raise


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def timestamp(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("candidate timestamp requires a timezone")
    return parsed


def stable_version(value: str) -> tuple[int, int, int]:
    match = VERSION.fullmatch(value.removeprefix("v"))
    if not match or match[4]:
        raise ValueError(f"Expected stable semantic version, got {value!r}")
    return tuple(int(match[i]) for i in (1, 2, 3))


def emit(values: dict) -> None:
    for key, value in values.items():
        value = str(value)
        if "\n" in value or "\r" in value:
            raise ValueError("multiline job output is not allowed")
        if path := os.environ.get("GITHUB_OUTPUT"):
            with open(path, "a") as handle:
                handle.write(f"{key}={value}\n")
    print(json.dumps(values, indent=2))


def check_ci(repo: str, sha: str, ci_run: dict) -> None:
    workflow_id = api(f"repos/{repo}/actions/workflows/ci.yml")["id"]
    if not (
        ci_run["workflow_id"] == workflow_id
        and ci_run["head_sha"] == sha
        and ci_run["head_branch"] == "main"
        and ci_run["event"] in ("push", "workflow_dispatch")
        and ci_run["head_repository"]["full_name"] == repo
        and ci_run["status"] == "completed"
        and ci_run["conclusion"] == "success"
    ):
        raise ValueError("A successful trusted main CI run on the exact source commit is required")


def source(args) -> None:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repo = os.environ["GITHUB_REPOSITORY"]
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Release preparation must execute from main")
    automatic = os.environ["GITHUB_EVENT_NAME"] == "workflow_run"
    ci_run = event.get("workflow_run") if automatic else None
    sha = ci_run["head_sha"] if automatic else os.environ["GITHUB_SHA"]
    if not SHA.fullmatch(sha):
        raise ValueError("Invalid release source SHA")
    if automatic:
        # Ignore failed runs and foreign events before acquiring any credentials.
        if ci_run.get("conclusion") != "success" or ci_run.get("event") != "push":
            emit({"eligible": "false"})
            return
    run("git", "fetch", "origin", "main", "--tags")
    run("git", "merge-base", "--is-ancestor", sha, "origin/main")
    if not automatic:
        runs = api(f"repos/{repo}/actions/workflows/ci.yml/runs?head_sha={sha}&branch=main&per_page=100")["workflow_runs"]
        trusted = [r for r in runs if r["event"] in ("push", "workflow_dispatch")]
        if not trusted:
            raise ValueError("No main CI run exists for this commit. Run CI first, then resume release preparation.")
        ci_run = max(trusted, key=lambda r: r["id"])
    ci_run = api(f"repos/{repo}/actions/runs/{ci_run['id']}")
    check_ci(repo, sha, ci_run)
    # An ordinary main push must not turn into a release. Automatic candidates
    # require the version metadata commit produced by prepare-release.sh.
    if automatic:
        changed = set(run("git", "diff-tree", "--no-commit-id", "--name-only", "-r", sha).splitlines())
        if changed != {PLIST, "CHANGELOG.md"} or not run("git", "show", "-s", "--format=%s", sha).startswith("release: v"):
            emit({"eligible": "false"})
            return
    metadata = plistlib.loads(run("git", "show", f"{sha}:{PLIST}").encode())
    version = metadata["CFBundleShortVersionString"]
    if not VERSION.fullmatch(version) or not str(metadata["CFBundleVersion"]).isdigit():
        raise ValueError("Invalid release version/build")
    channel = "stable" if automatic else args.channel
    latest = optional_api(f"repos/{repo}/releases/latest")
    if channel == "stable":
        stable_version(version)
        tag = f"v{version}"
        if latest and stable_version(latest["tag_name"]) >= stable_version(version):
            if automatic:
                emit({"eligible": "false"})
                return
            raise ValueError("This version is already published or older than latest; choose tester for an intentional test build")
    else:
        tag = f"workspaces-v{version}-main.{os.environ['GITHUB_RUN_ID']}"
    existing = optional_api(f"repos/{repo}/git/ref/tags/{tag}")
    if existing and (existing["object"]["type"] != "commit" or existing["object"]["sha"] != sha):
        raise ValueError("Existing tag does not identify this exact source commit")
    values = {
        "eligible": "true", "source": sha, "tag": tag, "channel": channel,
        "version": version, "build": str(metadata["CFBundleVersion"]),
        "bundle_id": metadata["CFBundleIdentifier"], "public_key": metadata["SUPublicEDKey"],
        "ci_url": ci_run["html_url"], "ci_run_id": str(ci_run["id"]),
        "previous_stable_tag": latest["tag_name"] if latest else "",
    }
    emit(values)


def digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected regular candidate file: {path.name}")
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def release_notes(changelog: str, version: str) -> str:
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog, re.M | re.S)
    if not match or not match[1].strip():
        raise ValueError(f"No release notes for {version}")
    return match[1].strip() + "\n"


def expected(args) -> dict:
    return {"commitSha": args.source, "tag": args.tag, "version": args.version, "build": args.build}


def validate_assets(directory: Path, manifest: dict, identity: dict) -> None:
    for key, value in identity.items():
        if manifest.get(key) != value:
            raise ValueError(f"Candidate {key} does not match the qualified source")
    names = {"dmg": f"WorkSpaces-{identity['version']}.dmg", "latestDmg": "WorkSpaces-latest.dmg", "appcast": "appcast.xml"}
    if set(manifest["assets"]) != set(names):
        raise ValueError("Unexpected manifest asset set")
    for key, name in names.items():
        asset = manifest["assets"][key]
        if asset["name"] != name:
            raise ValueError("Unexpected asset filename")
        path = directory / name
        if digest(path) != asset["sha256"] or path.stat().st_size != asset["size"]:
            raise ValueError(f"Candidate asset changed: {name}")
    if manifest["assets"]["dmg"]["sha256"] != manifest["assets"]["latestDmg"]["sha256"]:
        raise ValueError("Latest DMG differs from the versioned DMG")


def seal(args) -> None:
    directory = args.directory
    manifest = json.loads((directory / "release-manifest.json").read_text())
    validate_assets(directory, manifest, expected(args))
    (directory / "release-notes.md").write_text(release_notes((ROOT / "CHANGELOG.md").read_text(), args.version))
    files = [a["name"] for a in manifest["assets"].values()] + ["release-manifest.json", "release-notes.md", "benchmark-check.txt"]
    candidate = {
        "schemaVersion": 1, **expected(args), "channel": args.channel,
        "repository": os.environ["GITHUB_REPOSITORY"], "runId": os.environ["GITHUB_RUN_ID"],
        "runAttempt": os.environ["GITHUB_RUN_ATTEMPT"], "createdAt": now().isoformat(),
        "ciRunId": args.ci_run_id, "previousStableTag": args.previous_stable_tag,
        "files": {name: digest(directory / name) for name in files},
    }
    (directory / "candidate.json").write_text(json.dumps(candidate, indent=2) + "\n")
    emit({"candidate_sha256": digest(directory / "candidate.json")})


def verify(args) -> dict:
    directory = args.directory
    if digest(directory / "candidate.json") != args.candidate_sha256:
        raise ValueError("Candidate identity changed after preparation")
    candidate = json.loads((directory / "candidate.json").read_text())
    for key, value in {"schemaVersion": 1, **expected(args), "channel": args.channel, "repository": os.environ["GITHUB_REPOSITORY"], "runId": os.environ["GITHUB_RUN_ID"]}.items():
        if candidate.get(key) != value:
            raise ValueError(f"Candidate {key} mismatch")
    age = now() - timestamp(candidate["createdAt"])
    if age < dt.timedelta(0) or age > MAX_AGE:
        raise ValueError("Candidate expired; build and review a fresh candidate")
    manifest = json.loads((directory / "release-manifest.json").read_text())
    names = {f"WorkSpaces-{args.version}.dmg", "WorkSpaces-latest.dmg", "appcast.xml", "release-manifest.json", "release-notes.md", "benchmark-check.txt"}
    if set(candidate["files"]) != names or {p.name for p in directory.iterdir()} != names | {"candidate.json"}:
        raise ValueError("Unexpected candidate file set")
    for name, sha in candidate["files"].items():
        if digest(directory / name) != sha:
            raise ValueError(f"Candidate file changed: {name}")
    validate_assets(directory, manifest, expected(args))
    print(f"Verified immutable candidate {args.tag} at {args.source}")
    return candidate


def summary(args) -> None:
    candidate = verify(args)
    notes = (args.directory / "release-notes.md").read_text()
    benchmark = (args.directory / "benchmark-check.txt").read_text().strip()
    repo = os.environ["GITHUB_REPOSITORY"]
    previous = candidate.get("previousStableTag")
    rollback = f"[Previous stable release](https://github.com/{repo}/releases/tag/{previous})" if previous else "No previous stable release recorded."
    body = f"""## {args.tag} is ready for publication

Version **{args.version}**, build **{args.build}**, source `{args.source}`.

[Download the signed candidate]({args.artifact_url}) for optional manual testing.
Extract the ZIP and open `WorkSpaces-{args.version}.dmg`. Publication uses this
same installer without rebuilding. Candidate expires seven days after preparation.

**Approve the `release-publication` deployment to publish.** The public stable release and
Sparkle feed have not changed. No reply in chat or manual test confirmation is required.
{rollback} is the recovery reference; changing latest does not downgrade already
updated installations. A corrective update needs a higher build number.

### Completed checks

- [Exact-commit main CI](https://github.com/{repo}/actions/runs/{candidate['ciRunId']}) passed.
- Developer ID bundle signature, provisioning profile, and notarization passed.
- Downloaded candidate: manifest, asset hashes, Sparkle signature, DMG ticket,
  Gatekeeper, and packaged CLI launch passed.
- Installer SHA-256: `{candidate['files'][f'WorkSpaces-{args.version}.dmg']}`.
- Full GUI/Sparkle upgrade is available for optional manual testing; the packaged
  CLI smoke check does not claim a GUI upgrade was exercised.

### Benchmark policy

```text
{benchmark}
```

### Release notes

{notes}
"""
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
        handle.write(body)


def publish(args) -> None:
    candidate = verify(args)
    repo = os.environ["GITHUB_REPOSITORY"]
    latest = optional_api(f"repos/{repo}/releases/latest")
    if args.channel == "stable" and latest and stable_version(latest["tag_name"]) > stable_version(args.version):
        raise ValueError("Refusing to replace a newer stable release")
    # The approval binds the artifact and source. Never manufacture a new tag
    # from whichever main commit happens to exist at publication time.
    tag = optional_api(f"repos/{repo}/git/ref/tags/{args.tag}")
    if tag:
        if tag["object"]["type"] != "commit" or tag["object"]["sha"] != args.source:
            raise ValueError("Stable tag points at a different source")
    else:
        api(f"repos/{repo}/git/refs", method="POST", data={"ref": f"refs/tags/{args.tag}", "sha": args.source})
    releases = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    matching = [r for page in releases for r in page if r["tag_name"] == args.tag]
    if len(matching) > 1:
        raise ValueError("Ambiguous release identity")
    marker = f"<!-- candidate:{args.candidate_sha256} source:{args.source} -->"
    notes = (args.directory / "release-notes.md").read_text() + "\n" + marker + "\n"
    release = matching[0] if matching else api(f"repos/{repo}/releases", method="POST", data={
        "tag_name": args.tag, "target_commitish": args.source, "name": f"WorkSpaces {args.tag}",
        "body": notes, "draft": True, "prerelease": args.channel == "tester",
    })
    if marker not in (release.get("body") or ""):
        raise ValueError("Existing release belongs to another candidate; it will not be overwritten")
    asset_names = {f"WorkSpaces-{args.version}.dmg", "WorkSpaces-latest.dmg", "appcast.xml", "release-manifest.json"}
    remote_assets = {a["name"] for a in release["assets"]}
    if remote_assets - asset_names:
        raise ValueError("Existing release has unexpected assets")
    if not release["draft"] and remote_assets != asset_names:
        raise ValueError("Published release is incomplete; refusing to mutate it")
    # Resume a partially uploaded draft without replacing any existing asset.
    for name in sorted(asset_names - remote_assets):
        run("gh", "release", "upload", args.tag, str(args.directory / name), "--repo", repo)
    with tempfile.TemporaryDirectory(prefix="release-verify-") as temp:
        run("gh", "release", "download", args.tag, "--repo", repo, "--dir", temp)
        for name in asset_names:
            if digest(Path(temp) / name) != candidate["files"][name]:
                raise ValueError(f"Uploaded asset differs from the approved candidate: {name}")
    if release["draft"]:
        verify(args)
        latest = optional_api(f"repos/{repo}/releases/latest")
        if args.channel == "stable" and latest and stable_version(latest["tag_name"]) > stable_version(args.version):
            raise ValueError("Refusing to replace a newer stable release")
        api(f"repos/{repo}/releases/{release['id']}", method="PATCH", data={
            "draft": False, "make_latest": "true" if args.channel == "stable" else "false",
        })
    print(f"Published https://github.com/{repo}/releases/tag/{args.tag}")


def publish_with_retry(args) -> None:
    # Reconcile remote state on each attempt: an uncertain API response may
    # already have created the tag, draft, asset, or final release. Never repeat
    # a blind create/upload, and never retry a candidate/identity rejection.
    for attempt in range(3):
        try:
            publish(args)
            return
        except RuntimeError as error:
            if attempt == 2:
                raise
            print(f"Transient publication failure; reconciling the same candidate: {error}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("source", "seal", "verify", "summary", "publish"))
    parser.add_argument("--channel", choices=("stable", "tester"), default="stable")
    parser.add_argument("--directory", type=Path, default=Path("release-assets"))
    parser.add_argument("--previous-stable-tag", default="")
    for name in ("source", "tag", "version", "build", "candidate-sha256", "ci-run-id", "artifact-url"):
        parser.add_argument(f"--{name}")
    args = parser.parse_args()
    if args.command != "source":
        if not args.source or not SHA.fullmatch(args.source) or not args.version or not VERSION.fullmatch(args.version) or not args.build or not args.build.isdigit():
            parser.error("valid --source, --version and --build are required")
        if not args.tag or not re.fullmatch(r"(?:v|workspaces-v)[0-9A-Za-z.-]+", args.tag):
            parser.error("invalid --tag")
        wanted_tag = f"v{args.version}" if args.channel == "stable" else f"workspaces-v{args.version}-main.{os.environ['GITHUB_RUN_ID']}"
        if args.tag != wanted_tag:
            parser.error("--tag must identify this version, channel, and run")
        if args.channel == "stable":
            stable_version(args.version)
        if args.command != "seal" and not re.fullmatch(r"[0-9a-f]{64}", args.candidate_sha256 or ""):
            parser.error("--candidate-sha256 is required")
    (publish_with_retry if args.command == "publish" else globals()[args.command])(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f"release-candidate: {error}", file=sys.stderr)
        sys.exit(1)
