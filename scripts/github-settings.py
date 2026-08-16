#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Config-as-code for GitHub repo settings: repository rulesets and environments.

Desired state lives in config/github/rulesets/<name>.json and
config/github/environments/<name>.json, each matched to live settings by its
"name" field. `check` exits 1 with a diff when live settings drift from the
files; `apply` pushes the files to GitHub (admin token); `snapshot` overwrites
the files from live state. Auth via `gh` / GH_TOKEN.

Environments carry protection rules and deployment branch policies only. Secret
*names* are audited separately by scripts/audit-security-posture.py, which stays
the single source of truth for them; secret values never appear here.
"""

import argparse
import difflib
import json
import subprocess
import sys
from pathlib import Path

CONFIG_DIR = Path(__file__).resolve().parent.parent / "config" / "github"
RULESETS_DIR = CONFIG_DIR / "rulesets"
ENVIRONMENTS_DIR = CONFIG_DIR / "environments"
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
    return json.loads(result.stdout or b"{}")


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
    # bypass_actors is deliberately not managed here: a read-only token (the
    # Actions token in the drift workflow) cannot see it, so tracking it would
    # make every CI check disagree with every admin check. Normalising to []
    # on both sides keeps the comparison honest about what this file covers.
    # apply() carries the live value across so the field is never rewritten
    # from this empty placeholder — see apply_ruleset.
    desired["bypass_actors"] = []
    return json.dumps(desired, indent=2, sort_keys=True) + "\n"


def desired_files() -> list[Path]:
    files = sorted(RULESETS_DIR.glob("*.json"))
    if not files:
        sys.exit(f"no ruleset files in {RULESETS_DIR}")
    return files


def live_ids_by_name(repo: str) -> dict[str, int]:
    return {r["name"]: r["id"] for r in gh_api(f"repos/{repo}/rulesets")}


# --- environments ------------------------------------------------------------
#
# Reviewers are stored by login rather than numeric id: the id is an
# implementation detail that makes diffs unreadable, and `apply` resolves it
# back. Reviewers are always written on apply — the environments PUT clears
# them when the field is omitted, which would silently drop the human approval
# gate on `release`.


def environment_files() -> list[Path]:
    return sorted(ENVIRONMENTS_DIR.glob("*.json")) if ENVIRONMENTS_DIR.is_dir() else []


def render_environment(name: str, live: dict, branch_policies: list[dict]) -> str:
    rules = live.get("protection_rules") or []
    by_type = {rule.get("type"): rule for rule in rules}
    reviewer_rule = by_type.get("required_reviewers", {})
    wait_rule = by_type.get("wait_timer", {})
    desired = {
        "name": name,
        "wait_timer": wait_rule.get("wait_timer", 0),
        "prevent_self_review": reviewer_rule.get("prevent_self_review", False),
        "reviewers": sorted(
            (
                {
                    "type": entry.get("type"),
                    "login": (entry.get("reviewer") or {}).get("login")
                    or (entry.get("reviewer") or {}).get("slug"),
                }
                for entry in reviewer_rule.get("reviewers", [])
            ),
            key=lambda item: (item["type"] or "", item["login"] or ""),
        ),
        "deployment_branch_policy": live.get("deployment_branch_policy"),
        "branch_policies": sorted(
            ({"type": policy["type"], "name": policy["name"]} for policy in branch_policies),
            key=lambda item: (item["type"], item["name"]),
        ),
    }
    return json.dumps(desired, indent=2, sort_keys=True) + "\n"


def gh_api_optional(path: str) -> dict | None:
    """GET that distinguishes "absent" from "could not read".

    A 404 returns None; anything else still exits, so a permissions failure is
    never reported as a missing environment.
    """
    result = subprocess.run(
        ["gh", "api", path], capture_output=True, text=True
    )
    if result.returncode == 0:
        return json.loads(result.stdout or "{}")
    if "HTTP 404" in result.stderr or "Not Found" in result.stderr:
        return None
    sys.exit(f"gh api GET {path} failed: {result.stderr.strip()}")


def live_environment(repo: str, name: str) -> str | None:
    live = gh_api_optional(f"repos/{repo}/environments/{name}")
    if live is None:
        return None
    policies: list[dict] = []
    if (live.get("deployment_branch_policy") or {}).get("custom_branch_policies"):
        payload = gh_api(f"repos/{repo}/environments/{name}/deployment-branch-policies")
        policies = payload.get("branch_policies", []) if isinstance(payload, dict) else []
    return render_environment(name, live, policies)


def normalise_environment_file(path: Path) -> tuple[str, str]:
    desired = json.loads(path.read_text())
    name = desired["name"]
    desired.setdefault("wait_timer", 0)
    desired.setdefault("prevent_self_review", False)
    desired.setdefault("reviewers", [])
    desired.setdefault("deployment_branch_policy", None)
    desired.setdefault("branch_policies", [])
    desired["reviewers"] = sorted(
        desired["reviewers"], key=lambda item: (item.get("type", ""), item.get("login", ""))
    )
    desired["branch_policies"] = sorted(
        desired["branch_policies"], key=lambda item: (item.get("type", ""), item.get("name", ""))
    )
    return name, json.dumps(desired, indent=2, sort_keys=True) + "\n"


def reviewer_id(login: str, kind: str) -> int:
    path = f"orgs/{login}" if kind == "Team" else f"users/{login}"
    return int(gh_api(path)["id"])


def apply_environment(repo: str, path: Path) -> None:
    name, rendered = normalise_environment_file(path)
    desired = json.loads(rendered)
    body = {
        "wait_timer": desired["wait_timer"],
        "prevent_self_review": desired["prevent_self_review"],
        "reviewers": [
            {"type": entry["type"], "id": reviewer_id(entry["login"], entry["type"])}
            for entry in desired["reviewers"]
        ],
        "deployment_branch_policy": desired["deployment_branch_policy"],
    }
    gh_api(f"repos/{repo}/environments/{name}", "PUT", body)

    if not (desired["deployment_branch_policy"] or {}).get("custom_branch_policies"):
        print(f"applied: environment '{name}' <- {path.name}")
        return

    payload = gh_api(f"repos/{repo}/environments/{name}/deployment-branch-policies")
    existing = payload.get("branch_policies", []) if isinstance(payload, dict) else []
    live_keys = {(policy["type"], policy["name"]): policy["id"] for policy in existing}
    wanted_keys = {(policy["type"], policy["name"]) for policy in desired["branch_policies"]}
    for key in sorted(wanted_keys - set(live_keys)):
        gh_api(
            f"repos/{repo}/environments/{name}/deployment-branch-policies",
            "POST",
            {"type": key[0], "name": key[1]},
        )
    for key, policy_id in sorted(live_keys.items()):
        if key not in wanted_keys:
            gh_api(
                f"repos/{repo}/environments/{name}/deployment-branch-policies/{policy_id}",
                "DELETE",
            )
    print(f"applied: environment '{name}' <- {path.name}")


def check_environments(repo: str) -> int:
    drift = 0
    for path in environment_files():
        name, wanted = normalise_environment_file(path)
        live = live_environment(repo, name)
        if live is None:
            print(f"DRIFT: environment '{name}' ({path.name}) does not exist on {repo}")
            drift = 1
            continue
        if live == wanted:
            print(f"OK: environment '{name}' matches {path.name}")
        else:
            print(f"DRIFT: environment '{name}' differs from {path.name}:")
            sys.stdout.writelines(
                difflib.unified_diff(
                    live.splitlines(keepends=True),
                    wanted.splitlines(keepends=True),
                    fromfile=f"live/{name}",
                    tofile=f"config/github/environments/{path.name}",
                )
            )
            drift = 1
    return drift


# --- commands ----------------------------------------------------------------


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
    return max(drift, check_environments(repo))


def apply_ruleset(repo: str, path: Path, live_ids: dict[str, int]) -> None:
    desired = json.loads(render(json.loads(path.read_text())))
    name = desired["name"]
    if name not in live_ids:
        gh_api(f"repos/{repo}/rulesets", "POST", desired)
        print(f"created: ruleset '{name}' <- {path.name}")
        return
    # Carry the live bypass_actors across rather than sending render()'s empty
    # placeholder, which would strip the repository-admin bypass as a silent
    # side effect of applying an unrelated rule change.
    live = gh_api(f"repos/{repo}/rulesets/{live_ids[name]}")
    desired["bypass_actors"] = live.get("bypass_actors", []) if isinstance(live, dict) else []
    gh_api(f"repos/{repo}/rulesets/{live_ids[name]}", "PUT", desired)
    print(f"applied: ruleset '{name}' <- {path.name} (bypass_actors left as-is)")


def apply(repo: str) -> int:
    live_ids = live_ids_by_name(repo)
    for path in desired_files():
        apply_ruleset(repo, path, live_ids)
    for path in environment_files():
        apply_environment(repo, path)
    return 0


def snapshot(repo: str) -> int:
    live_ids = live_ids_by_name(repo)
    for path in desired_files():
        name = json.loads(path.read_text())["name"]
        if name not in live_ids:
            sys.exit(f"ruleset '{name}' ({path.name}) does not exist on {repo}")
        path.write_text(render(gh_api(f"repos/{repo}/rulesets/{live_ids[name]}")))
        print(f"snapshot: {path.name} <- live ruleset '{name}'")
    for path in environment_files():
        name = json.loads(path.read_text())["name"]
        live = live_environment(repo, name)
        if live is None:
            sys.exit(f"environment '{name}' ({path.name}) does not exist on {repo}")
        path.write_text(live)
        print(f"snapshot: {path.name} <- live environment '{name}'")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "apply", "snapshot"])
    args = parser.parse_args()
    return {"check": check, "apply": apply, "snapshot": snapshot}[args.command](repo_slug())


if __name__ == "__main__":
    sys.exit(main())
