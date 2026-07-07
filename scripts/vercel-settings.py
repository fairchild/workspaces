#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Config-as-code for Vercel env vars (spaces-web + web-next projects).

Desired state lives in config/vercel/<project>.json: `values` are non-secret
flags checked by value; `present` are secrets checked by name only (their
values never appear in-repo or in output). `check` exits 1 on drift; `apply`
reconciles `values` keys (then a redeploy is needed to take effect);
`snapshot` refreshes manifest values from live. Auth via logged-in `vercel`
CLI or VERCEL_TOKEN. Membership in `values` is explicit curation — never
classify by readability, since a var's sensitive flag can be misconfigured.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_DIR = REPO_ROOT / "config" / "vercel"
ENV_LINE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)="(.*)"$')


def vercel_cmd(*args: str) -> list[str]:
    cmd = shlex.split(os.environ.get("VERCEL_BIN", "vercel")) + list(args)
    if token := os.environ.get("VERCEL_TOKEN"):
        cmd += ["--token", token]
    return cmd


def run(cmd: list[str], cwd: Path, input_text: str | None = None) -> str:
    result = subprocess.run(cmd, cwd=cwd, input=input_text, capture_output=True, text=True)
    if result.returncode != 0:
        redacted = [a for a in cmd if a != os.environ.get("VERCEL_TOKEN")]
        sys.exit(f"command failed: {' '.join(redacted)}\n{result.stderr.strip()}")
    return result.stdout


def manifests() -> list[dict]:
    files = sorted(MANIFEST_DIR.glob("*.json"))
    if not files:
        sys.exit(f"no manifests in {MANIFEST_DIR}")
    return [{"path": f, **json.loads(f.read_text())} for f in files]


def ensure_link(m: dict) -> Path:
    project_dir = REPO_ROOT / m["dir"]
    link = project_dir / ".vercel" / "project.json"
    if link.exists() and json.loads(link.read_text()).get("projectName") == m["project"]:
        return project_dir
    run(vercel_cmd("link", "--yes", "--scope", m["scope"], "--project", m["project"]), cwd=project_dir)
    return project_dir


def pull_env(m: dict) -> dict[str, str]:
    project_dir = ensure_link(m)
    with tempfile.TemporaryDirectory() as tmp:
        env_file = Path(tmp) / "pulled.env"
        run(
            vercel_cmd("env", "pull", str(env_file), "--environment", m["environment"], "--yes"),
            cwd=project_dir,
        )
        pairs = {}
        for line in env_file.read_text().splitlines():
            if match := ENV_LINE.match(line):
                pairs[match.group(1)] = match.group(2)
        return pairs


def check(m: dict) -> int:
    live = pull_env(m)
    drift = 0
    for key, expected in m["values"].items():
        if key not in live:
            print(f"DRIFT [{m['project']}] {key}: missing in {m['environment']}")
            drift = 1
        elif live[key] != expected:
            print(f"DRIFT [{m['project']}] {key}: live={live[key]!r} expected={expected!r}")
            drift = 1
    for key in m["present"]:
        if key not in live:
            print(f"DRIFT [{m['project']}] {key}: secret missing in {m['environment']}")
            drift = 1
    if not drift:
        print(f"OK [{m['project']}] {len(m['values'])} values + {len(m['present'])} secrets match")
    return drift


def apply(m: dict) -> int:
    live = pull_env(m)
    project_dir = REPO_ROOT / m["dir"]
    changed = []
    for key, expected in m["values"].items():
        if live.get(key) == expected:
            continue
        if key in live:
            run(vercel_cmd("env", "rm", key, m["environment"], "--yes"), cwd=project_dir)
        run(vercel_cmd("env", "add", key, m["environment"]), cwd=project_dir, input_text=expected)
        changed.append(key)
        print(f"applied [{m['project']}] {key}")
    if changed:
        print(f"NOTE [{m['project']}]: env changes take effect on the NEXT deploy — redeploy to activate")
    else:
        print(f"no-op [{m['project']}]: all values already match")
    return 0


def snapshot(m: dict) -> int:
    live = pull_env(m)
    for key in m["values"]:
        if key not in live:
            sys.exit(f"[{m['project']}] {key} not in live {m['environment']} env; cannot snapshot")
        m["values"][key] = live[key]
    manifest = {k: m[k] for k in ("project", "scope", "dir", "environment", "values", "present")}
    manifest["present"] = sorted(manifest["present"])
    m["path"].write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"snapshot [{m['project']}] -> {m['path'].name}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "apply", "snapshot"])
    args = parser.parse_args()
    action = {"check": check, "apply": apply, "snapshot": snapshot}[args.command]
    return max(action(m) for m in manifests())


if __name__ == "__main__":
    sys.exit(main())
