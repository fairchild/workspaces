#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Configure candidate signing and publication without unlocking historical runs.

The legacy release environment keeps its reviewer protection. New signing uses
release-candidate; only release-publication asks for approval in the new flow.
Settings setup never exports or copies secrets; the existing setup helper loads
candidate credentials from the operator's signing files.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LEGACY = "release"
SIGNING = "release-candidate"
PUBLICATION = "release-publication"
POLICY = {"protected_branches": False, "custom_branch_policies": True}
SIGNING_SECRETS = {
    "APPLE_API_ISSUER_ID", "APPLE_API_KEY_BASE64", "APPLE_API_KEY_ID",
    "APPLE_DEVELOPER_ID_CERT_BASE64", "APPLE_DEVELOPER_ID_CERT_PASSWORD",
    "APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64", "SPARKLE_PRIVATE_KEY",
}


def api(path: str, method="GET", data=None):
    args = ["gh", "api", path, "--method", method]
    if data is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=json.dumps(data) if data is not None else None, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout or "null")


def optional_environment(repo: str, name: str) -> dict:
    try:
        return api(f"repos/{repo}/environments/{name}")
    except RuntimeError as error:
        if "HTTP 404" not in str(error):
            raise
        return {}


def reviewers(environment: dict) -> list[dict]:
    return [r for rule in environment.get("protection_rules", []) if rule["type"] == "required_reviewers" for r in rule["reviewers"]]


def human_gate(environment: dict) -> bool:
    return any(r["type"] == "User" and r["reviewer"].get("type") == "User" for r in reviewers(environment))


def main_only(repo: str, name: str) -> bool:
    policies = api(f"repos/{repo}/environments/{name}/deployment-branch-policies")["branch_policies"]
    return [(p["name"], p["type"]) for p in policies] == [("main", "branch")]


def validate_gate(repo: str, name: str, value: dict) -> None:
    if not value:
        raise ValueError(f"{name} is missing; apply the reviewed release environment setup first")
    if name == PUBLICATION:
        if not human_gate(value):
            raise ValueError("Publication requires an explicit human reviewer gate")
        if value.get("can_admins_bypass") is not False:
            raise ValueError("Publication approval must not allow an administrator bypass")
    elif reviewers(value):
        raise ValueError("Candidate signing still requires approval")
    if value.get("deployment_branch_policy") != POLICY or not main_only(repo, name):
        raise ValueError(f"{name} must allow only the main branch, with no tag or wildcard policy")
    allowed = {"branch_policy", "required_reviewers"} if name == PUBLICATION else {"branch_policy"}
    if any(rule["type"] not in allowed for rule in value.get("protection_rules", [])):
        raise ValueError(f"{name} has unexpected deployment gates")


def secret_names(repo: str, name: str) -> set[str]:
    return {s["name"] for s in api(f"repos/{repo}/environments/{name}/secrets?per_page=100")["secrets"]}


def check(repo: str, *, settings=False) -> None:
    legacy = optional_environment(repo, LEGACY)
    if not human_gate(legacy) or legacy.get("can_admins_bypass") is not False:
        raise ValueError("Keep the legacy release environment human-gated; historical workflows can still rerun")
    for name in (PUBLICATION, SIGNING):
        validate_gate(repo, name, optional_environment(repo, name))
    if settings:
        # Secret metadata needs operator permissions that GITHUB_TOKEN does not
        # carry. Check this during setup and the host security audit; never read
        # values. Workflow jobs also omit every signing-secret reference outside
        # the signing job.
        if secret_names(repo, PUBLICATION):
            raise ValueError("release-publication must have no environment secrets")
        missing = SIGNING_SECRETS - secret_names(repo, SIGNING)
        if missing:
            raise ValueError("Candidate signing secrets are not configured: " + ", ".join(sorted(missing)))
    print("Release gates verified: legacy approval preserved; main-only candidate signing and human publication.")


def restrict_main(repo: str, name: str) -> None:
    path = f"repos/{repo}/environments/{name}/deployment-branch-policies"
    policies = api(path)["branch_policies"]
    if not any(p["name"] == "main" and p["type"] == "branch" for p in policies):
        api(path, "POST", {"name": "main", "type": "branch"})
    for policy in policies:
        if (policy["name"], policy["type"]) != ("main", "branch"):
            api(f"{path}/{policy['id']}", "DELETE")


def apply(repo: str) -> None:
    workflow = api(f"repos/{repo}/contents/.github/workflows/release.yml?ref=main")
    remote = base64.b64decode(workflow["content"])
    if remote != (ROOT / ".github/workflows/release.yml").read_bytes() or b"environment: release-candidate" not in remote:
        raise ValueError("Merge the reviewed candidate workflow first; local release.yml must equal remote main")
    rules = api(f"repos/{repo}/rules/branches/main")
    if not any(r["type"] == "pull_request" and r.get("parameters", {}).get("required_approving_review_count", 0) >= 1 for r in rules):
        raise ValueError("main requires an approving PR review; candidate qualification independently verifies the released commit range")
    legacy = optional_environment(repo, LEGACY)
    if not human_gate(legacy) or legacy.get("can_admins_bypass") is not False:
        raise ValueError("The legacy release reviewer gate must remain intact")
    publication = optional_environment(repo, PUBLICATION)
    reviewer_source = reviewers(publication) or reviewers(legacy)
    if not any(r["type"] == "User" and r["reviewer"].get("type") == "User" for r in reviewer_source):
        raise ValueError("No existing human release reviewer to preserve")
    required = [{"type": r["type"], "id": r["reviewer"]["id"]} for r in reviewer_source]
    base = {"deployment_branch_policy": POLICY, "wait_timer": 0, "prevent_self_review": False, "can_admins_bypass": False}
    api(f"repos/{repo}/environments/{PUBLICATION}", "PUT", {**base, "reviewers": required})
    restrict_main(repo, PUBLICATION)
    validate_gate(repo, PUBLICATION, optional_environment(repo, PUBLICATION))
    if secret_names(repo, PUBLICATION):
        raise ValueError("Publication environment contains secrets; candidate settings were not changed")
    # Only the new environment becomes automatic. Never remove reviewers or
    # change refs on LEGACY, including during retries and partial setup failures.
    api(f"repos/{repo}/environments/{SIGNING}", "PUT", {**base, "reviewers": required})
    restrict_main(repo, SIGNING)
    candidate = optional_environment(repo, SIGNING)
    validate_gate(repo, SIGNING, {**candidate, "protection_rules": [r for r in candidate.get("protection_rules", []) if r["type"] != "required_reviewers"]})
    missing = SIGNING_SECRETS - secret_names(repo, SIGNING)
    if missing:
        raise ValueError("Candidate settings prepared with approval still required. Configure these secrets in release-candidate, then rerun apply: " + ", ".join(sorted(missing)))
    api(f"repos/{repo}/environments/{SIGNING}", "PUT", {**base, "reviewers": []})
    check(repo, settings=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apply"))
    parser.add_argument("--repo", default="fairchild/workspaces")
    parser.add_argument("--settings", action="store_true", help="Also audit secret scopes with operator credentials")
    args = parser.parse_args()
    if args.command == "apply":
        apply(args.repo)
    else:
        check(args.repo, settings=args.settings)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError) as error:
        print(f"release-environments: {error}", file=sys.stderr)
        sys.exit(1)
