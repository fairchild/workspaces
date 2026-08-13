#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Refresh every mise pin in the repo to the latest stable upstream release.

`--check` (the default) exits 3 when the pin is stale, 0 when current; `--apply`
rewrites the version across PIN_SITES, taking the linux-x64 sha256 from
upstream's SHASUMS256.txt. Run weekly by a scheduled Claude routine
(.claude/commands/mise-pin-refresh.md, #866); also runnable locally.

Sites are listed, not discovered, and their format is declared: the workflow
pins feed jdx/mise-action, which takes a bare version, while everything else
carries the tag as upstream writes it. Registration is enforced from the other
side — test_security_hardening.py fails when a workflow uses mise-action without
appearing here, which is what let release.yml's pin age until upstream pruned
its assets and it 404'd mid-release (#1297).
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# (path, prefix) — "v" carries upstream's tag verbatim, "" is a bare version.
PIN_SITES = (
    ("scripts/verify-mise-security.sh", "v"),
    ("web/src/lib/agent-runtime/vercel-sandbox.ts", "v"),
    ("scripts/tests/test_security_hardening.py", "v"),
    (".github/workflows/release.yml", ""),
    (".github/workflows/ci.yml", ""),
)
VERIFIER = REPO_ROOT / PIN_SITES[0][0]
MISE_ACTION = "jdx/mise-action@"
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"


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


def workflows_using_mise_action() -> set[str]:
    """Repo-relative paths of workflows with a jdx/mise-action step.

    Both extensions: GitHub accepts .yaml, and a pin this script never sees is
    the exact problem being guarded against.
    """
    return {
        str(path.relative_to(REPO_ROOT))
        for pattern in ("*.yml", "*.yaml")
        for path in WORKFLOW_DIR.glob(pattern)
        if MISE_ACTION in path.read_text()
    }


def rewrite(text: str, prefix: str, old: str, new: str, old_sha: str, new_sha: str) -> str:
    """Point one site at the new version.

    Bare sites are matched through their `version:` key rather than on the
    version alone, so a matrix entry, a block scalar, or another action's input
    elsewhere in the same workflow cannot be caught by the rewrite.
    """
    if prefix:
        return text.replace(old, new).replace(old_sha, new_sha)
    return text.replace(
        f"version: {old.removeprefix('v')}", f"version: {new.removeprefix('v')}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="rewrite pin sites")
    parser.add_argument("--check", action="store_true", help="report only (the default)")
    args = parser.parse_args()

    old_version, old_sha = current_pin()
    new_version = latest_stable()
    if new_version == old_version:
        print(f"pin {old_version} is current")
        return 0
    print(f"stale: pin {old_version} -> latest stable {new_version}")
    if not args.apply:
        return 3

    new_sha = upstream_sha(new_version)
    # Every site is rewritten in memory and checked before anything is written.
    # A site that has drifted out of sync therefore aborts the run instead of
    # leaving the tree half-updated with the verifier already claiming the new
    # version — which reads as current on the next run and hides the rest.
    pending: list[tuple[Path, str]] = []
    for site, prefix in PIN_SITES:
        path = REPO_ROOT / site
        text = path.read_text()
        updated = rewrite(text, prefix, old_version, new_version, old_sha, new_sha)
        if updated == text:
            sys.exit(f"{site}: no pin occurrences found; refresh script out of sync")
        pending.append((path, updated))

    for path, text in pending:
        path.write_text(text)
        print(f"updated {path.relative_to(REPO_ROOT)}")
    print(f"sha256 {new_sha} (from upstream SHASUMS256.txt)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
