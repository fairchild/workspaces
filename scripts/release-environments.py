#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check or migrate the existing release environments for candidate publication.

Signing secrets remain on release. The migration creates and verifies the
publication reviewer gate before making signing automatic on main. It replaces
the old single environment policy, without copying or exposing credentials.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SIGNING = "release"
PUBLICATION = "release-publication"
POLICY = {"protected_branches": False, "custom_branch_policies": True}


def api(path: str, method="GET", data=None):
    args = ["gh", "api", path, "--method", method]
    if data is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(data) if data is not None else None, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout or "null")


def reviewers(environment: dict) -> list[dict]:
    return [r for rule in environment.get("protection_rules", []) if rule["type"] == "required_reviewers" for r in rule["reviewers"]]


def main_only(repo: str, name: str) -> bool:
    policies = api(f"repos/{repo}/environments/{name}/deployment-branch-policies")["branch_policies"]
    return [(p["name"], p["type"]) for p in policies] == [("main", "branch")]


def check(repo: str) -> None:
    signing = api(f"repos/{repo}/environments/{SIGNING}")
    publication = api(f"repos/{repo}/environments/{PUBLICATION}")
    if reviewers(signing):
        raise ValueError("Signing still requires approval; migrate release environments before preparing a candidate")
    if not reviewers(publication):
        raise ValueError("Publication requires an explicit human reviewer gate")
    if not any(r["type"] == "User" and r["reviewer"].get("type") == "User" for r in reviewers(publication)):
        raise ValueError("Publication must name a human reviewer")
    if publication.get("can_admins_bypass") is not False:
        raise ValueError("Publication approval must not allow an administrator bypass")
    for name, value in ((SIGNING, signing), (PUBLICATION, publication)):
        if value.get("deployment_branch_policy") != POLICY or not main_only(repo, name):
            raise ValueError(f"{name} must allow only the main branch, with no tag or wildcard policy")
        allowed = {"branch_policy", "required_reviewers"} if name == PUBLICATION else {"branch_policy"}
        if any(rule["type"] not in allowed for rule in value.get("protection_rules", [])):
            raise ValueError(f"{name} has unexpected deployment gates")
    print("Release policy verified: automatic main-only signing, human-approved main-only publication.")


def restrict_main(repo: str, name: str) -> None:
    path = f"repos/{repo}/environments/{name}/deployment-branch-policies"
    policies = api(path)["branch_policies"]
    # Add the intended rule before removing other rules; reviewer protection
    # remains intact throughout this part of migration.
    if not any(p["name"] == "main" and p["type"] == "branch" for p in policies):
        api(path, "POST", {"name": "main", "type": "branch"})
    for policy in policies:
        if (policy["name"], policy["type"]) != ("main", "branch"):
            api(f"{path}/{policy['id']}", "DELETE")


def apply(repo: str) -> None:
    # Settings must not make the old main workflow publish without approval.
    workflow = api(f"repos/{repo}/contents/.github/workflows/release.yml?ref=main")
    remote = base64.b64decode(workflow["content"])
    local = (ROOT / ".github/workflows/release.yml").read_bytes()
    if remote != local or b"name: release-publication" not in remote or b"validate-candidate" not in remote:
        raise ValueError("Merge the reviewed candidate workflow first; local release.yml must equal remote main")
    rules = api(f"repos/{repo}/rules/branches/main")
    if not any(r["type"] == "pull_request" and r.get("parameters", {}).get("required_approving_review_count", 0) >= 1 for r in rules):
        raise ValueError("main requires an approving PR review before signing may become automatic")
    # Existing waiting jobs could start as soon as reviewers are removed.
    # Never cancel someone else's release silently or unlock an old run.
    for status in ("queued", "in_progress", "waiting", "pending", "requested"):
        runs = api(f"repos/{repo}/actions/workflows/release.yml/runs?status={status}&per_page=100")["workflow_runs"]
        if runs:
            raise ValueError("Finish or explicitly cancel active release runs before migration: " + ", ".join(str(r["id"]) for r in runs))
    signing = api(f"repos/{repo}/environments/{SIGNING}")
    try:
        publication = api(f"repos/{repo}/environments/{PUBLICATION}")
    except RuntimeError as error:
        if "HTTP 404" not in str(error):
            raise
        publication = {}
    reviewer_source = reviewers(publication) or reviewers(signing)
    if not any(r["type"] == "User" and r["reviewer"].get("type") == "User" for r in reviewer_source):
        raise ValueError("No existing human release reviewer to preserve")
    required = [{"type": r["type"], "id": r["reviewer"]["id"]} for r in reviewer_source]
    base = {"deployment_branch_policy": POLICY, "wait_timer": 0, "prevent_self_review": False, "can_admins_bypass": False}
    api(f"repos/{repo}/environments/{PUBLICATION}", "PUT", {**base, "reviewers": required})
    restrict_main(repo, PUBLICATION)
    new_gate = api(f"repos/{repo}/environments/{PUBLICATION}")
    if not reviewers(new_gate) or not main_only(repo, PUBLICATION):
        raise ValueError("Replacement publication gate did not verify; signing protection remains unchanged")
    # Restrict signing refs while it still carries its existing reviewer gate.
    old_reviewers = [{"type": r["type"], "id": r["reviewer"]["id"]} for r in reviewers(signing)]
    api(f"repos/{repo}/environments/{SIGNING}", "PUT", {**base, "reviewers": old_reviewers})
    restrict_main(repo, SIGNING)
    if not main_only(repo, SIGNING):
        raise ValueError("Signing main-only policy did not verify")
    api(f"repos/{repo}/environments/{SIGNING}", "PUT", {**base, "reviewers": []})
    check(repo)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apply"))
    parser.add_argument("--repo", default="fairchild/workspaces")
    args = parser.parse_args()
    (apply if args.command == "apply" else check)(args.repo)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError) as error:
        print(f"release-environments: {error}", file=sys.stderr)
        sys.exit(1)
