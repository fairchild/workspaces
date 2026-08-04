#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Diff config/github/repo-variables.json against live GitHub repo variables.

Desired state is the manifest's key set: every FACTORY_*_ENABLED kill switch
a workflow gates on. `scripts/tests/test_factory_workflows.py` covers half of
this contract (every vars.FACTORY_*_ENABLED referenced under
.github/workflows/ has a manifest entry) from local files only. This script
covers the other half: does each manifest entry actually exist as a live repo
variable. Two sources for "live," picked automatically:

- CI: `.github/workflows/repo-variables-drift.yml` sets REPO_VARS_JSON to
  `${{ toJSON(vars) }}` before calling this script. The `vars` context is
  populated by Actions for every job — unlike the `gh variable list` REST
  endpoint, no elevated GITHUB_TOKEN permission is needed, so this runs
  unattended (`vars` context: https://docs.github.com/actions/reference/workflows-and-actions/contexts#vars-context).
- Local/manual: REPO_VARS_JSON is normally unset, so this falls back to
  `gh variable list` (needs a `gh` authenticated with variable-read access —
  a PAT, not the ambient Actions token).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "config" / "github" / "repo-variables.json"


def live_variable_names() -> set[str]:
    raw = os.environ.get("REPO_VARS_JSON")
    if raw:
        live = json.loads(raw)
        if not isinstance(live, dict):
            sys.exit("REPO_VARS_JSON did not decode to an object")
        # An unset repo variable reads as empty string in Actions expressions,
        # so it can show up as a key with an empty value rather than being
        # absent — either way it can't gate a workflow to true.
        return {name for name, value in live.items() if value}

    result = subprocess.run(
        ["gh", "variable", "list", "--json", "name", "-q", ".[].name"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"gh variable list failed: {result.stderr.strip()}")
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def main() -> int:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    desired = set(manifest.keys())
    live = live_variable_names()
    missing = sorted(desired - live)
    if missing:
        print("In config/github/repo-variables.json but not live/unset (gate can never fire):")
        for name in missing:
            print(f"  - {name}   fix: gh variable set {name} --body true")
        return 1
    print(f"OK — all {len(desired)} manifest variables exist live.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
