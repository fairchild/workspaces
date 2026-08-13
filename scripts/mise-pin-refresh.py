#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Refresh every mise pin in the repo to the latest stable upstream release.

`--check` exits 3 when the pin is stale (0 when current); `--apply` rewrites the
pin version + linux-x64 sha256 across the literal pin sites, taking the sha from
upstream's SHASUMS256.txt, and rewrites the version of every `jdx/mise-action`
step in .github/workflows. Run weekly by a scheduled Claude routine
(.claude/commands/mise-pin-refresh.md, #866); also runnable locally.

Workflow pins are discovered, not listed. release.yml's pin sat outside this
script's roster until upstream pruned its assets and it 404'd mid-release
(#1297) — a pin nothing refreshes is worse than no pin, and a hardcoded roster
is how one goes unnoticed.
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# Sites carrying the version as upstream writes it, tag prefix and all.
PIN_SITES = (
    "scripts/verify-mise-security.sh",
    "web/src/lib/agent-runtime/vercel-sandbox.ts",
    "scripts/tests/test_security_hardening.py",
)
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
VERIFIER = REPO_ROOT / PIN_SITES[0]
# jdx/mise-action takes a bare version; the `v` prefix is not accepted there.
MISE_ACTION = "jdx/mise-action@"
VERSION_LINE = re.compile(r"(\s+version:\s*)(\S+)(\s*)$")
NEXT_ITEM = re.compile(r"\s+- (uses|name):")


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=30) as resp:
        return resp.read()


def current_pin() -> tuple[str, str]:
    text = VERIFIER.read_text()
    version = re.search(r'^MISE_EXPECTED_VERSION="(v[^"]+)"', text, re.M).group(1)
    sha = re.search(r'^MISE_EXPECTED_LINUX_X64_SHA256="([0-9a-f]{64})"', text, re.M).group(1)
    return version, sha


def latest_stable() -> str:
    release = json.loads(fetch("https://api.github.com/repos/jdx/mise/releases/latest"))
    if release["draft"] or release["prerelease"]:
        sys.exit(f"latest mise release {release['tag_name']} is a draft/prerelease; refusing")
    return release["tag_name"]


def upstream_sha(version: str) -> str:
    shasums = fetch(
        f"https://github.com/jdx/mise/releases/download/{version}/SHASUMS256.txt"
    ).decode()
    for line in shasums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == f"./mise-{version}-linux-x64":
            return parts[0]
    sys.exit(f"mise-{version}-linux-x64 not found in upstream SHASUMS256.txt")


def workflow_pin_sites() -> list[Path]:
    """Every workflow that pins mise through jdx/mise-action."""
    return sorted(p for p in WORKFLOW_DIR.glob("*.yml") if MISE_ACTION in p.read_text())


def rewrite_workflow_pin(text: str, bare_version: str) -> tuple[str, int, int]:
    """Point each jdx/mise-action step at bare_version.

    Returns the new text, how many action steps carried a `version:`, and how
    many of those had to change. Scanning line by line rather than parsing YAML
    keeps this dependency-free; the walk stops at the next list item so a later
    step's `version:` can never be captured by an earlier action.
    """
    lines = text.splitlines(keepends=True)
    found = changed = 0
    for index, line in enumerate(lines):
        if MISE_ACTION not in line:
            continue
        for offset in range(index + 1, min(index + 12, len(lines))):
            match = VERSION_LINE.match(lines[offset])
            if match:
                found += 1
                if match.group(2) != bare_version:
                    lines[offset] = f"{match.group(1)}{bare_version}{match.group(3)}"
                    changed += 1
                break
            if NEXT_ITEM.match(lines[offset]):
                break
    return "".join(lines), found, changed


def workflow_drift(pinned: str) -> list[tuple[Path, str]]:
    """Workflow pins that disagree with the managed version."""
    drift = []
    for path in workflow_pin_sites():
        _, found, changed = rewrite_workflow_pin(path.read_text(), pinned.removeprefix("v"))
        if found == 0:
            drift.append((path, "no version: on its jdx/mise-action step"))
        elif changed:
            drift.append((path, f"not pinned to {pinned}"))
    return drift


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="rewrite pin sites (default: check only)")
    args = parser.parse_args()

    old_version, old_sha = current_pin()
    drift = workflow_drift(old_version)
    for path, why in drift:
        print(f"drift: {path.relative_to(REPO_ROOT)} {why}")

    new_version = latest_stable()
    if new_version == old_version and not drift:
        print(f"pin {old_version} is current")
        return 0
    if new_version != old_version:
        print(f"stale: pin {old_version} -> latest stable {new_version}")
    if not args.apply:
        return 3

    if new_version != old_version:
        new_sha = upstream_sha(new_version)
        for site in PIN_SITES:
            path = REPO_ROOT / site
            text = path.read_text()
            updated = text.replace(old_version, new_version).replace(old_sha, new_sha)
            if updated == text:
                sys.exit(f"{site}: no pin occurrences found; refresh script out of sync")
            path.write_text(updated)
            print(f"updated {site}")
        print(f"sha256 {new_sha} (from upstream SHASUMS256.txt)")

    bare = new_version.removeprefix("v")
    for path in workflow_pin_sites():
        text = path.read_text()
        updated, found, changed = rewrite_workflow_pin(text, bare)
        rel = path.relative_to(REPO_ROOT)
        if found == 0:
            sys.exit(f"{rel}: jdx/mise-action step has no version: to update")
        if changed:
            path.write_text(updated)
            print(f"updated {rel} ({changed} mise-action pin(s) -> {bare})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
