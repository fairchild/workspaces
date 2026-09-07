#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Prepare or resume a WorkSpaces release through its metadata PR.

This is the repo-owned release entry point for people and release skills. It
replaces manual branch/PR/merge/tag orchestration; CI prepares the candidate
after the metadata merge, and only its publication asks for human approval.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import sys


ROOT = Path(__file__).resolve().parents[1]
METADATA = {"CHANGELOG.md", "Sources/WorkspaceManager/Resources/Info.plist"}


def run(*args: str, cwd: Path = ROOT, check=True) -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=180)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Stable X.Y.Z; default follows merged conventional commits")
    parser.add_argument("--notes-file", type=Path, help="Reviewed Markdown body for this changelog section")
    parser.add_argument("--dry-run", action="store_true", help="Print the version and commit range only")
    parser.add_argument("--status", action="store_true", help="Read the metadata PR and recent release runs")
    args = parser.parse_args()
    repo = run("gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")
    run("git", "fetch", "origin", "main", "--tags")
    latest = json.loads(run("gh", "api", f"repos/{repo}/releases/latest"))
    last = latest["tag_name"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", last):
        raise ValueError("Latest release must have a stable semantic tag")
    commits = run("git", "log", f"{last}..origin/main", "--format=%s", "--no-merges")
    major, minor, patch = map(int, last[1:].split("."))
    breaking = bool(re.search(r"^\w+(?:\([^)]*\))?!:", commits, re.M))
    feature = bool(re.search(r"^feat(?:\([^)]*\))?:", commits, re.M))
    suggestion = f"{major + 1}.0.0" if breaking and major else f"{major}.{minor + 1}.0" if breaking or feature else f"{major}.{minor}.{patch + 1}"
    version = (args.version or suggestion).removeprefix("v")
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        parser.error("--version must be stable X.Y.Z")
    branch = f"codex-release-v{version}"
    prs = json.loads(run("gh", "pr", "list", "--repo", repo, "--head", branch, "--state", "all", "--json", "number,url,state,headRefOid,mergeCommit"))
    if len(prs) > 1:
        raise ValueError("Multiple metadata PRs exist for this version; reconcile them first")
    if args.status:
        print(json.dumps({"latest": latest["html_url"], "metadata_pr": prs}, indent=2))
        print(run("gh", "run", "list", "--repo", repo, "--workflow", "release.yml", "--limit", "5"))
        return
    if args.dry_run:
        print(f"Version: {version}\nBase: {run('git', 'rev-parse', 'origin/main')}\nChanges since {last}:\n{commits}")
        return
    if prs and prs[0]["state"] == "MERGED":
        print(f"Metadata already merged: {prs[0]['url']}\nCandidate preparation follows successful main CI. Use --status to inspect progress.")
        return
    if prs and prs[0]["state"] != "OPEN":
        raise ValueError("This version's metadata PR was closed; choose an unused version")
    if tuple(map(int, version.split("."))) <= (major, minor, patch):
        raise ValueError("Release version must be newer than latest stable")
    if not prs:
        if not commits:
            raise ValueError("No changes since the latest stable release")
        if run("git", "ls-remote", "origin", f"refs/heads/{branch}") or run("git", "show-ref", "--verify", f"refs/heads/{branch}", check=False):
            raise ValueError(f"Branch {branch} exists without a PR; inspect it before resuming")
        directory = Path(tempfile.mkdtemp(prefix=f"workspaces-release-{version}-"))
        run("git", "worktree", "add", "-b", branch, str(directory), "origin/main")
        # Preserve this worktree on any failure so edited notes and metadata
        # remain recoverable. Successful work is pushed before cleanup.
        print(f"Release worktree: {directory}", flush=True)
        print(run("./scripts/prepare-release.sh", "--version", version, "--metadata-only", cwd=directory))
        if args.notes_file:
            notes = args.notes_file.resolve().read_text().strip()
            if not notes or re.search(r"^## \[", notes, re.M):
                raise ValueError("--notes-file must contain only this release's nonempty section body")
            path = directory / "CHANGELOG.md"
            text = path.read_text()
            pattern = rf"(^## \[{re.escape(version)}\][^\n]*\n).*?(?=^## \[|\Z)"
            path.write_text(re.sub(pattern, lambda m: m[1] + "\n" + notes + "\n\n", text, count=1, flags=re.M | re.S))
        run("./scripts/generate-sparkle-appcast.sh", "--notes-only", "--version", version, cwd=directory)
        run("uv", "run", "--script", "scripts/tests/test_sparkle_release_notes.py", cwd=directory)
        run("git", "diff", "--check", cwd=directory)
        changed = set(run("git", "diff", "--name-only", cwd=directory).splitlines())
        if changed != METADATA:
            raise ValueError("Release preparation changed files beyond version metadata and changelog")
        run("git", "add", *sorted(METADATA), cwd=directory)
        run("git", "commit", "-m", f"release: v{version}", cwd=directory)
        run("git", "fetch", "origin", "main", cwd=directory)
        run("git", "rebase", "origin/main", cwd=directory)
        run("git", "push", "-u", "origin", branch, cwd=directory)
        body = f"""## Summary

Prepare WorkSpaces v{version}. Candidate CI builds and validates the signed installer after the metadata merge. Publication requires the single release-publication environment approval.

## Mergeability

- Surface: desktop release metadata.
- User-facing behavior changed: Version/build metadata and release notes only.
- Non-happy paths considered: Duplicate version, unexpected file changes, tag/version mismatch, malformed Sparkle notes, and stale benchmarks are checked before submission.
- Release/ops preconditions: Candidate signing and publication environments must pass release-environments.py check. Exact merged-commit CI and signed candidate validation must pass before the publication approval appears.
- Residual risk or follow-up: Signing, candidate validation, and public Sparkle verification run after merge; failures block the next stage. Laptop benchmark freshness remains governed by its existing policy.

## Validation

- Release metadata preparation and benchmark policy passed.
- Sparkle release-note tests and notes-only rendering passed.
- git diff --check passed.

## Performance

- [x] Not a performance-sensitive change. This PR changes version metadata and changelog only.

## Evidence

- [x] Not a testable change (metadata/config only). Runtime changes were reviewed in their implementing PRs. Release-note validation ran before submission; signed artifact evidence is produced by candidate CI.

<!-- release-entrypoint:{version} -->
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md") as file:
            file.write(body); file.flush()
            run("uv", "run", "--script", "scripts/pr-readiness.py", "--body-file", file.name, "--title", f"release: v{version}", cwd=directory)
            print(run("gh", "pr", "create", "--repo", repo, "--base", "main", "--head", branch, "--title", f"release: v{version}", "--body-file", file.name, "--label", "author:codex", cwd=directory))
        run("git", "worktree", "remove", str(directory))
    pr = json.loads(run("gh", "pr", "view", branch, "--repo", repo, "--json", "number,url,headRefOid,files,body"))
    if {f["path"] for f in pr["files"]} != METADATA or f"<!-- release-entrypoint:{version} -->" not in pr["body"]:
        raise ValueError("Existing PR is not the expected metadata-only release request")
    # Auto-merge preserves repository review/check requirements. No admin
    # override and no final environment approval are performed by this tool.
    run("gh", "pr", "merge", str(pr["number"]), "--repo", repo, "--auto", "--squash", "--match-head-commit", pr["headRefOid"])
    print(f"{pr['url']}\nAuto-merge enabled after required review and checks. Candidate CI then prepares the publication approval.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print(f"release: {error}", file=sys.stderr)
        sys.exit(1)
