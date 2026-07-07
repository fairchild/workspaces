#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Refresh the sandbox mise pin to the latest stable upstream release.

`--check` exits 3 when the pin is stale (0 when current); `--apply` rewrites
the pin version + linux-x64 sha256 in the three pin sites, taking the sha
from upstream's SHASUMS256.txt. Driven weekly by mise-pin-refresh.yml, which
maintains at most one open bump PR; also runnable locally.
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PIN_SITES = (
    "scripts/verify-mise-security.sh",
    "web/src/lib/agent-runtime/vercel-sandbox.ts",
    "scripts/tests/test_security_hardening.py",
)
VERIFIER = REPO_ROOT / PIN_SITES[0]


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="rewrite pin sites (default: check only)")
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
    for site in PIN_SITES:
        path = REPO_ROOT / site
        text = path.read_text()
        updated = text.replace(old_version, new_version).replace(old_sha, new_sha)
        if updated == text:
            sys.exit(f"{site}: no pin occurrences found; refresh script out of sync")
        path.write_text(updated)
        print(f"updated {site}")
    print(f"sha256 {new_sha} (from upstream SHASUMS256.txt)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
