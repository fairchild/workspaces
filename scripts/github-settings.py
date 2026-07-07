#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Config-as-code for GitHub repo settings (currently: repository rulesets).

Desired state lives in config/github/rulesets/<name>.json, matched to live
rulesets by their "name" field. `check` exits 1 with a diff when live settings
drift from the files; `apply` pushes the files to GitHub (admin token);
`snapshot` overwrites the files from live state. Auth via `gh` / GH_TOKEN.
"""

import argparse
import difflib
import json
import subprocess
import sys
from pathlib import Path

RULESETS_DIR = Path(__file__).resolve().parent.parent / "config" / "github" / "rulesets"
WRITABLE_FIELDS = ("name", "target", "enforcement", "bypass_actors", "conditions", "rules")


def gh_api(path: str, method: str = "GET", body: dict | None = None) -> dict | list:
    cmd = ["gh", "api", "-X", method, path]
    stdin = None
    if body is not None:
        cmd += ["--input", "-"]
        stdin = json.dumps(body).encode()
    try:
        result = subprocess.run(cmd, input=stdin, capture_output=True, check=True)
    except subprocess.CalledProcessError as err:
        sys.exit(f"gh api {method} {path} failed: {err.stderr.decode().strip()}")
    return json.loads(result.stdout)


def repo_slug() -> str:
    result = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        capture_output=True,
        check=True,
        text=True,
    )
    return result.stdout.strip()


def render(ruleset: dict) -> str:
    desired = {key: ruleset[key] for key in WRITABLE_FIELDS if key in ruleset}
    # Read-only tokens (e.g. the Actions token in the drift workflow) get the
    # ruleset without bypass_actors; treat absent as empty so they compare
    # cleanly. Actual bypass-actor drift is still caught by admin-side checks.
    desired.setdefault("bypass_actors", [])
    return json.dumps(desired, indent=2, sort_keys=True) + "\n"


def desired_files() -> list[Path]:
    files = sorted(RULESETS_DIR.glob("*.json"))
    if not files:
        sys.exit(f"no ruleset files in {RULESETS_DIR}")
    return files


def live_ids_by_name(repo: str) -> dict[str, int]:
    return {r["name"]: r["id"] for r in gh_api(f"repos/{repo}/rulesets")}


def check(repo: str) -> int:
    live_ids = live_ids_by_name(repo)
    drift = 0
    for path in desired_files():
        desired = json.loads(path.read_text())
        name = desired["name"]
        if name not in live_ids:
            print(f"DRIFT: ruleset '{name}' ({path.name}) does not exist on {repo}")
            drift = 1
            continue
        live = render(gh_api(f"repos/{repo}/rulesets/{live_ids[name]}"))
        wanted = render(desired)
        if live == wanted:
            print(f"OK: ruleset '{name}' matches {path.name}")
        else:
            print(f"DRIFT: ruleset '{name}' differs from {path.name}:")
            sys.stdout.writelines(
                difflib.unified_diff(
                    live.splitlines(keepends=True),
                    wanted.splitlines(keepends=True),
                    fromfile=f"live/{name}",
                    tofile=f"config/github/rulesets/{path.name}",
                )
            )
            drift = 1
    return drift


def apply(repo: str) -> int:
    live_ids = live_ids_by_name(repo)
    for path in desired_files():
        desired = json.loads(render(json.loads(path.read_text())))
        name = desired["name"]
        if name in live_ids:
            gh_api(f"repos/{repo}/rulesets/{live_ids[name]}", "PUT", desired)
            print(f"applied: ruleset '{name}' <- {path.name}")
        else:
            gh_api(f"repos/{repo}/rulesets", "POST", desired)
            print(f"created: ruleset '{name}' <- {path.name}")
    return 0


def snapshot(repo: str) -> int:
    live_ids = live_ids_by_name(repo)
    for path in desired_files():
        name = json.loads(path.read_text())["name"]
        if name not in live_ids:
            sys.exit(f"ruleset '{name}' ({path.name}) does not exist on {repo}")
        path.write_text(render(gh_api(f"repos/{repo}/rulesets/{live_ids[name]}")))
        print(f"snapshot: {path.name} <- live ruleset '{name}'")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "apply", "snapshot"])
    args = parser.parse_args()
    return {"check": check, "apply": apply, "snapshot": snapshot}[args.command](repo_slug())


if __name__ == "__main__":
    sys.exit(main())
