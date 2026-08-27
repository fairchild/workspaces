#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Complete named-CI evidence items on factory PRs (#1120).

Trusted-lane verifier: reads the live conclusion of each named check on the
PR head, flips matching evidence entries complete/pending in the PR body, and
clears a machine-applied blocked:evidence label only when every entry is
complete and SHA-current. Fail-closed: unknown shapes are skipped and
human-applied labels are never removed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CONTRIBUTOR_SCRIPTS = REPO_ROOT / ".agents" / "skills" / "cofounder-contributor" / "scripts"
if str(CONTRIBUTOR_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(CONTRIBUTOR_SCRIPTS))

from evidence import (  # noqa: E402
    _ci_check_name,
    _evidence_item_kind,
    _extract_evidence_metadata,
    check_runs_for,
    update_evidence_entries,
)
from execution import APP_BOT_GIT_IDENTITIES  # noqa: E402

FACTORY_PR_MARKER = "<!-- contributor:issue="
BLOCKED_EVIDENCE_LABEL = "blocked:evidence"
GH_TIMEOUT = 60
VALID_STATUSES = {"complete", "blocked", "pending-ci"}
MAX_WRITE_ATTEMPTS = 3

# Identities whose label application counts as machine-applied. Derived from
# the contributor identity table so reviewer-only apps never qualify.
FACTORY_LABEL_ACTORS = frozenset(
    identity["login"] for identity in APP_BOT_GIT_IDENTITIES.values()
)


def log(message: str) -> None:
    print(f"[factory-evidence-verify] {message}", file=sys.stderr)


def _gh(args: list[str], env: dict[str, str]) -> bool:
    try:
        result = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=True,
            env=env,
            timeout=GH_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return False
    if result.returncode != 0 and result.stderr.strip():
        log(result.stderr.strip())
    return result.returncode == 0


def _gh_json(args: list[str], env: dict[str, str]) -> object | None:
    try:
        result = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=True,
            env=env,
            timeout=GH_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def open_prs_for_head(head_sha: str, env: dict[str, str]) -> list[dict[str, object]]:
    payload = _gh_json(
        ["api", f"repos/{{owner}}/{{repo}}/commits/{head_sha}/pulls"],
        env,
    )
    if not isinstance(payload, list):
        return []
    return [
        pr
        for pr in payload
        if isinstance(pr, dict)
        and pr.get("state") == "open"
        and isinstance(pr.get("head"), dict)
        and pr["head"].get("sha") == head_sha
    ]


def evidence_entries(body: str) -> list[object] | None:
    metadata = _extract_evidence_metadata(body)
    if not isinstance(metadata, dict):
        return None
    entries = metadata.get("entries")
    return entries if isinstance(entries, list) else None


def ci_entries_needing_verification(
    entries: list[object],
    head_sha: str,
) -> list[tuple[int, str]]:
    """(index, check name) for `ci` entries pending or stale against head."""
    needed: list[tuple[int, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        item = str(entry.get("item", "")).strip()
        if _evidence_item_kind(item) != "ci":
            continue
        check_name = _ci_check_name(item)
        if check_name is None:
            continue
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError):
            continue
        status = str(entry.get("status", "")).strip()
        recorded_sha = str(entry.get("verified_head_sha", "")).strip()
        if status == "pending-ci" or (status == "complete" and recorded_sha != head_sha):
            needed.append((index, check_name))
    return needed


def latest_completed_run(runs: list[dict[str, object]] | None) -> dict[str, object] | None:
    completed = [run for run in runs or [] if str(run.get("status", "")) == "completed"]
    if not completed:
        return None
    return max(completed, key=lambda run: str(run.get("completed_at", "")))


def entry_update_for_check_run(
    check_name: str,
    head_sha: str,
    run: dict[str, object] | None,
    *,
    check_known: bool = True,
) -> dict[str, object]:
    short = head_sha[:12]
    base: dict[str, object] = {"kind": "ci", "check_name": check_name}
    if run is None and not check_known:
        # Worth distinguishing from "not finished yet": an entry naming a
        # check that does not exist never completes, and without saying so the
        # PR sits there looking like CI is merely slow. Stated as an
        # observation rather than a verdict, because this lane fires per check
        # suite and a later suite can still create the run.
        return {
            **base,
            "status": "pending-ci",
            "detail": (
                f"no run of `{check_name}` exists on head {short} yet — it may not "
                "have been created, or the name in the evidence item may not match "
                "a check on this repository"
            ),
        }
    if run is None:
        return {
            **base,
            "status": "pending-ci",
            "detail": f"no completed run of `{check_name}` found on head {short}; waiting for checks",
        }
    url = str(run.get("html_url", "") or "").strip()
    link = f" — {url}" if url else ""
    conclusion = str(run.get("conclusion", "") or "").strip()
    if conclusion == "success":
        return {
            **base,
            "status": "complete",
            "detail": f"`{check_name}` green on head {short}{link}",
            "verified_head_sha": head_sha,
            "proof_url": url,
        }
    return {
        **base,
        "status": "pending-ci",
        "detail": f"latest `{check_name}` run on head {short} concluded {conclusion or 'unknown'}{link}",
    }


def should_clear_blocked_label(entries: list[object] | None, head_sha: str) -> bool:
    """Provably-safe auto-clear: every entry complete, every ci entry bound
    to the current head. Anything unexpected keeps the label."""
    if not entries:
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            return False
        if str(entry.get("status", "")).strip() != "complete":
            return False
        item = str(entry.get("item", "")).strip()
        if (
            _evidence_item_kind(item) == "ci"
            and str(entry.get("verified_head_sha", "")).strip() != head_sha
        ):
            return False
    return True


def blocked_label_applied_by_factory(pr_number: int, env: dict[str, str]) -> bool:
    events = _gh_json(
        [
            "api",
            "-X", "GET",
            f"repos/{{owner}}/{{repo}}/issues/{pr_number}/timeline",
            "-f", "per_page=100",
        ],
        env,
    )
    if not isinstance(events, list):
        return False
    last_actor = ""
    for event in events:
        if not isinstance(event, dict) or event.get("event") != "labeled":
            continue
        label = event.get("label")
        if not isinstance(label, dict) or label.get("name") != BLOCKED_EVIDENCE_LABEL:
            continue
        actor = event.get("actor")
        last_actor = str(actor.get("login", "")) if isinstance(actor, dict) else ""
    return last_actor in FACTORY_LABEL_ACTORS


def _write_pr_body(pr_number: int, body: str, env: dict[str, str]) -> bool:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".md", delete=False) as handle:
        handle.write(body)
        body_file = handle.name
    try:
        return _gh(["pr", "edit", str(pr_number), "--body-file", body_file], env)
    finally:
        try:
            os.unlink(body_file)
        except OSError:
            pass


def _updates_targeting_unchanged_entries(
    body: str,
    updates: dict[int, dict[str, object]],
) -> dict[int, dict[str, object]]:
    """Drop updates whose target index no longer names the check they were
    computed for — e.g. an owner retargeted that evidence line during a
    retry. `updates` is keyed by index and blind to entry content, so this
    is what keeps a stale CI result from landing on an unrelated entry."""
    entries = evidence_entries(body)
    if entries is None:
        return {}
    current_check_names: dict[int, str | None] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError):
            continue
        current_check_names[index] = _ci_check_name(str(entry.get("item", "")).strip())
    return {
        index: update
        for index, update in updates.items()
        if current_check_names.get(index) == update.get("check_name")
    }


def _apply_ci_updates(
    pr_number: int,
    head_sha: str,
    body: str,
    updates: dict[int, dict[str, object]],
    env: dict[str, str],
) -> str | None:
    """Write `updates` onto the PR body, guarded against concurrent edits.

    Re-reads the PR immediately before writing. A moved head SHA means the
    PR advanced past what `updates` was computed against, so the write is
    skipped outright (next check_suite event self-heals). A body that no
    longer matches what was read at the top of `process_pr` — same SHA, but
    an owner edited the description in the UI in between — means writing
    `updates` now would clobber that edit; instead, re-apply `updates` to
    the freshly-read body and re-check, up to MAX_WRITE_ATTEMPTS times.
    Before each reapply, updates are narrowed to entries still naming the
    check they were computed for (see `_updates_targeting_unchanged_entries`),
    so a mid-flight edit to the evidence block itself can drop a stale
    result rather than misapply it. This does not close the write itself
    against a same-instant edit — `gh pr edit` has no conditional-write
    primitive — it narrows that window to the gap between the final
    match check and the write call. Returns the body now live on the PR
    (written, or already up to date), or None if the caller should stop
    without further evidence-state changes.
    """
    for attempt in range(1, MAX_WRITE_ATTEMPTS + 1):
        safe_updates = _updates_targeting_unchanged_entries(body, updates)
        if not safe_updates:
            return body
        new_body = update_evidence_entries(body, safe_updates)
        if new_body == body:
            return body
        current = _gh_json(["api", f"repos/{{owner}}/{{repo}}/pulls/{pr_number}"], env)
        current_head = current.get("head") if isinstance(current, dict) else None
        current_sha = str(current_head.get("sha", "")) if isinstance(current_head, dict) else ""
        if current_sha != head_sha:
            log(f"PR #{pr_number} advanced during verification; skipping write")
            return None
        current_body = str(current.get("body") or "") if isinstance(current, dict) else ""
        if current_body != body:
            log(
                f"PR #{pr_number} body changed during verification "
                f"(attempt {attempt}/{MAX_WRITE_ATTEMPTS}); re-applying evidence updates"
            )
            body = current_body
            continue
        if not _write_pr_body(pr_number, new_body, env):
            log(f"PR #{pr_number} body update failed")
            return None
        log(f"PR #{pr_number}: updated {len(safe_updates)} ci evidence entries")
        return new_body
    log(f"PR #{pr_number} body kept changing during verification; giving up without writing")
    return None


def process_pr(pr_number: int, env: dict[str, str]) -> None:
    pr = _gh_json(["api", f"repos/{{owner}}/{{repo}}/pulls/{pr_number}"], env)
    if not isinstance(pr, dict) or pr.get("state") != "open":
        return
    body = str(pr.get("body") or "")
    if FACTORY_PR_MARKER not in body:
        return
    head = pr.get("head")
    head_sha = str(head.get("sha", "")) if isinstance(head, dict) else ""
    if not head_sha:
        return
    entries = evidence_entries(body)
    if entries is None:
        return

    needed = ci_entries_needing_verification(entries, head_sha)
    if needed:
        updates: dict[int, dict[str, object]] = {}
        for index, check_name in needed:
            runs = check_runs_for(check_name, head_sha, env)
            updates[index] = entry_update_for_check_run(
                check_name,
                head_sha,
                latest_completed_run(runs),
                # None means the lookup itself failed, which says nothing about
                # whether the check exists -- only an answered query that came
                # back empty does.
                check_known=runs is None or bool(runs),
            )
        updated_body = _apply_ci_updates(pr_number, head_sha, body, updates, env)
        if updated_body is None:
            return
        body = updated_body

    label_names = {
        str(label.get("name", ""))
        for label in pr.get("labels", [])
        if isinstance(label, dict)
    }
    if BLOCKED_EVIDENCE_LABEL not in label_names:
        return
    if not should_clear_blocked_label(evidence_entries(body), head_sha):
        return
    if not blocked_label_applied_by_factory(pr_number, env):
        log(f"PR #{pr_number}: {BLOCKED_EVIDENCE_LABEL} was not machine-applied; leaving for the owner")
        return
    if _gh(["pr", "edit", str(pr_number), "--remove-label", BLOCKED_EVIDENCE_LABEL], env):
        log(f"PR #{pr_number}: cleared machine-applied {BLOCKED_EVIDENCE_LABEL}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--head-sha", help="Verify open factory PRs whose head is this commit.")
    group.add_argument("--pr", type=int, help="Re-verify one PR by number.")
    args = parser.parse_args(argv)
    env = dict(os.environ)

    if args.pr is not None:
        process_pr(args.pr, env)
        return 0

    prs = open_prs_for_head(args.head_sha, env)
    if not prs:
        log("no open PRs at this head; nothing to verify")
        return 0
    for pr in prs:
        try:
            process_pr(int(pr["number"]), env)
        except (KeyError, TypeError, ValueError):
            continue
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
