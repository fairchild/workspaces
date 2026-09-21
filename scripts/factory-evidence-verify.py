#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py==4.2.0"]
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
    # What an index is, and when two entries claim one, is ONE function in the
    # module that fans an update across a collision -- called here rather than
    # copied. Two definitions that agree is the shape this whole strand is
    # named for, and round 5 left one across the module boundary (#1778,
    # round 6).
    colliding_indexes,
    entries_by_index,
    usable_entry_index,
    update_evidence_entries,
)
from execution import APP_BOT_GIT_IDENTITIES, post_uncarried_notes  # noqa: E402

FACTORY_PR_MARKER = "<!-- contributor:issue="
BLOCKED_EVIDENCE_LABEL = "blocked:evidence"
REVIEW_WORKFLOW = "factory-review.yml"
CHANGES_REQUESTED = "CHANGES_REQUESTED"
# Reviewer identities whose standing rejection a completed evidence contract
# can supersede. Kept in step with factory-review.py's REVIEWER_BOTS.
REVIEWER_BOTS = frozenset({"april-clearwater[bot]", "workspace-agents[bot]"})
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
    """(index, check name) for every `ci` entry this lane can look up.

    Every one of them, whatever status it records and whatever head it claims
    to be bound to. It used to skip an entry already `complete` and bound to
    the current head, on the reading that such an entry had been verified
    already -- but what had been verified was whatever wrote it, and the
    thing that writes a pull request description is anyone with write access.
    A `{"status": "complete", "verified_head_sha": "<head>"}` typed into the
    block was never looked at again, and with `should_clear_blocked_label`
    reading the entries as recorded, the next run of this lane cleared the
    label it had applied itself without reading a single check run (#1778).

    So a completion is a claim this lane re-checks, on every run, against the
    live check runs on the head. The decision on the issue was re-verify
    rather than sign: one login covers many actors here, so a signature would
    prove what the block's existence already proves.

    `head_sha` is no longer read here and stays in the signature: it is what
    the entries are verified AGAINST, the caller passes it to
    `entry_update_for_check_run`, and a function that takes the head is the
    one a reader expects to be answering a question about the head.

    An entry with no extractable check name is still not this lane's business,
    which is the fail-closed rule #1120 set: a guessed check name verifies
    nothing and a wrong one fails an honest body.
    """
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
        # Usable, not merely claimed: an index nothing renders is a line no
        # reader sees, so looking a check up for it spends a call on nothing
        # and hands the clear a verdict about no line (#1778, round 7).
        index = usable_entry_index(entry)
        if index is None:
            continue
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


def verdict_is_definite(runs: list[dict[str, object]] | None) -> bool:
    """Whether this lookup SAYS something about the check, rather than failing to.

    Definite: an answered query that came back empty, which says the check
    does not exist on this head, and a lookup in which every run has finished
    -- whatever they concluded. Indefinite: a lookup that failed outright
    (`None`), and one holding a run that has not finished, which is a check
    mid-re-run.

    EVERY run, not the latest completed one. Asking for any completed run made
    this true for an older completed run sitting beside a newer `in_progress`
    one, so a recorded completion could be rewritten from a verdict the newer
    run is in the middle of replacing. The caller queries with
    `filter=latest`, which returns at most one run per app per check name, so
    that shape needs two apps publishing one name -- probably unreachable
    here, and unverified against the live API either way. A function whose
    correctness rests on what a query the caller happens to make returns is
    one that breaks when the caller changes; this one needs no precondition,
    and it needs no rule for which of two runs is newer (#1778, round 11).

    The difference decides whether a recorded completion may be rewritten.
    Demoting one on an indefinite answer wrote `pending-ci` into the body, and
    the NEXT run then read a completion where the one before had read none and
    spent a slot of the review budget on the transition -- which is exactly
    what the recorded reading exists to avoid, and which main did not do
    (#1778, round 2). Indefinite therefore fails toward the record standing.
    """
    if runs is None:
        return False
    return all(str(run.get("status", "")) == "completed" for run in runs)


def _recorded_contract_is_complete(entries: list[object] | None, head_sha: str) -> bool:
    """Whether the body ALREADY read as complete, taking the entries at their word.

    The reading `should_clear_blocked_label` used to have, kept for the one
    question where taking the record at its word is safe: whether this run
    changed anything. A forged body reads as complete here and the only thing
    that follows is that no review is requested, which costs a forger nothing
    and an honest author nothing either. Clearing a label is the question
    where it is not safe, and that one asks what this run verified (#1778).
    """
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


def should_clear_blocked_label(
    entries: list[object] | None,
    head_sha: str,
    *,
    verified: dict[int, dict[str, object]] | None = None,
) -> bool:
    """Provably-safe auto-clear: every entry complete, every ci entry verified BY THIS RUN.

    `verified` is what this run's own check-run reads concluded, keyed by
    entry index. A `ci` entry counts as complete only when it is in there
    complete and bound to this head -- not because the recorded entry says
    so, which is the half of #1778 that let a body clear its own label. With
    no `verified` in hand no `ci` entry can count, so a caller that forgot to
    pass it keeps the label rather than clearing it.

    What it quantifies over is the DESCRIPTION'S metadata, not the issue's
    contract: the contract's own name appears in this lane only in this
    sentence, and no code here reads it. So "every
    entry complete" means every entry the pull request body still records, and
    a requirement deleted from that block is not a requirement this gate can
    see -- deleting a `pending-ci` entry clears the label, and it does the same
    on main. Reading the contract here would need the issue the body closes and
    a rule for a body that records nothing the issue asks for, which is a
    larger change than re-checking a completion; it is #1783's family and the
    residual names it.

    What this does NOT close either, and it is worth saying where the function
    is rather than only in a pull request: a non-`ci` completion -- a test, a
    screenshot, the kinds the macOS lane resolves -- is counted as the entry
    records it, because this lane has no way to verify one. A completion of
    those written by hand still counts toward the clear. That is a provenance
    question about the lane that writes them, and the guide's section on what
    the metadata comment guarantees names it (#1712).

    Anything unexpected keeps the label.
    """
    if not entries:
        return False
    # Before anything about kinds. The guard widened to any kind in round 3
    # and this did not widen with it: the loop below skips a non-`ci` entry
    # before it ever reads an index, so two complete non-`ci` entries at one
    # index answered "every entry complete" and took the label off a contract
    # whose entries no reader can tell apart -- one definition of an index,
    # two definitions of which entries COUNT (#1778, round 5). A colliding
    # index is the same unanswerable question here as it is at the write, so
    # it gets the same answer: the label stays and the author is left the
    # contract.
    if colliding_indexes(entries):
        return False
    confirmed = verified or {}
    for entry in entries:
        if not isinstance(entry, dict):
            return False
        if str(entry.get("status", "")).strip() != "complete":
            return False
        # EVERY entry the clear counts, not only the `ci` ones. An entry whose
        # index nothing can act on renders no line, so counting it toward a
        # clear counts a requirement with nothing on the page for it: a
        # complete `diff` entry at `true`, `1.0`, `"1"`, `0`, `-1` or `null`
        # took the label off on its own. The int-only rule went in for the
        # acting path and stopped at the kind check here (#1778, round 10).
        index = usable_entry_index(entry)
        if index is None:
            return False
        item = str(entry.get("item", "")).strip()
        if _evidence_item_kind(item) != "ci":
            continue
        update = confirmed.get(index)
        if not isinstance(update, dict):
            return False
        # The verdict has to belong to the check THIS entry names. Looked up
        # by index alone, a decoy entry reusing an index and naming any green
        # check cleared the label on a red required one -- no race and no
        # forged status needed, just two entries at one index with the green
        # one written last (#1778, round 2). The write path already makes this
        # comparison (`_updates_targeting_unchanged_entries`); the clear made
        # none.
        if str(update.get("check_name", "")).strip() != (_ci_check_name(item) or ""):
            return False
        if str(update.get("status", "")).strip() != "complete":
            return False
        if str(update.get("verified_head_sha", "")).strip() != head_sha:
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
    # The same grouping the guard uses, so the two cannot disagree about what
    # an index is. An index more than one entry claims has no single check
    # name and keeps none: its updates are dropped here as well as refused
    # there (#1778, round 3).
    current_check_names: dict[int, str | None] = {
        index: (_ci_check_name(str(at[0].get("item", "")).strip()) if len(at) == 1 else None)
        for index, at in entries_by_index(entries).items()
    }
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

    The live read guards what this says as well as what it writes. A write
    that stands down leaves the body byte-identical and still owes the author
    a note, and that note is posted only while the head it names is still the
    head: when it has moved the note goes unsaid, and the next event says it
    against the head it belongs to.

    Three guards, one condition, and they are not depth: each covers a case
    the others cannot reach. The guard BEFORE the loop is what stops the
    check-run reads, which no narrowing can. The narrowing
    (`_updates_targeting_unchanged_entries`) refuses a collision arriving on
    the retry read at an index this run holds an update for, because it hands
    a colliding index no check name and drops the update. The guard INSIDE
    the loop covers what the narrowing structurally cannot see: a collision at
    an index this run holds NO update for. The narrowing only drops updates it
    holds, so on `{1: ci pending-ci, 2: diff complete}` with a twin injected
    at index 2, it has nothing to drop, the run writes and the label comes
    off with the collision intact. Round 4 measured this guard redundant and
    deleted it, and the measurement was of the suite rather than of the code:
    a surviving mutant means the code is redundant OR the suite cannot reach
    the case it covers, and only the second was true -- the fixture built
    collisions on the update's own index and nowhere else (#1778, round 5).
    """
    for attempt in range(1, MAX_WRITE_ATTEMPTS + 1):
        # The live PR first, before anything in this loop can return. Every
        # return here hands the caller a body it decides `blocked:evidence`
        # on, so a return that happens before the read decides on the copy
        # this run started from -- and an owner who retargets the one `ci`
        # entry mid-run then has the label cleared after two reads, zero
        # check-run verifications and zero writes. Round 7 moved the
        # extraction above two of the returns; this is the read itself, above
        # all of them (#1778, round 8).
        current = _gh_json(["api", f"repos/{{owner}}/{{repo}}/pulls/{pr_number}"], env)
        current_head = current.get("head") if isinstance(current, dict) else None
        current_sha = str(current_head.get("sha", "")) if isinstance(current_head, dict) else ""
        # `None` where the read told us nothing, "" where the PR's description
        # is genuinely empty (#1778, round 7).
        current_body = str(current.get("body") or "") if isinstance(current, dict) else None
        live = body if current_body is None else current_body
        if current_sha != head_sha:
            # Directly after the read and above every return, because a moved
            # head is not a decision to hand anyone: this run's conclusions
            # are about a commit the pull request has left, and `None` is how
            # this function says "take no decision". Below the two returns
            # that hand back the live body it was reachable -- read, the owner
            # retargets the entry, retry, the owner pushes, and the attempt
            # that drops every update returned a body for the caller to clear
            # the label on at a head nothing here verified (#1778, round 8).
            log(f"PR #{pr_number} advanced during verification; taking no decision")
            return None
        # Re-run on every body this loop is about to write, not once before
        # it. The retry re-reads a body an owner may have edited in between,
        # and a collision arriving there at an index this run holds no update
        # for reaches neither the pre-write guard (it had its turn) nor the
        # narrowing (it has no update to drop) -- so the run wrote the body
        # and cleared the label with the collision standing (#1778, rounds 3
        # and 5).
        if (shared := colliding_indexes(evidence_entries(body))):
            log(
                f"PR #{pr_number}: evidence entries share index(es) "
                f"{', '.join(str(index) for index in shared)}; leaving the contract for the author"
            )
            return live
        safe_updates = _updates_targeting_unchanged_entries(body, updates)
        if not safe_updates:
            # Nothing this run concluded still applies to the body in hand --
            # an owner retargeted the entry, or removed it. The label is
            # decided on what the pull request holds NOW, not on the copy this
            # run read first (#1778, round 8).
            return live
        uncarried: list[str] = []
        new_body = update_evidence_entries(body, safe_updates, announcements=uncarried)
        if new_body == body:
            # Same reason as the review-time completion: the write stands down
            # whole on a block whose closer never came, which returns the body
            # byte-identical, and returning here said it on stderr alone. A
            # stand-down is the case the author most needs telling about --
            # the section stands AND the status this run resolved is unwritten
            # (#1740, round 3). Read the live PR before saying so, the way the
            # writing path below does: a push in between would file the note
            # under a head the author has already left (#1740, round 4).
            post_uncarried_notes(pr_number, None, uncarried, head_sha, env)
            # The live body, so the label is decided on what the PR holds now
            # rather than on the copy this run started from. A read that told
            # us nothing leaves the body we have, which is the answer we had
            # anyway; an empty one is an answer.
            return live
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
        # This lane rewrites the author's section, so it drops the same text
        # the factory turn drops, and a step log is not where the author who
        # wrote that text is looking (#1740). Said after the write, because
        # the sentence is about a body GitHub now holds; without a persona,
        # because the verifier is not a character.
        post_uncarried_notes(pr_number, None, uncarried, head_sha, env)
        return new_body
    log(f"PR #{pr_number} body kept changing during verification; giving up without writing")
    return None


def standing_rejection(pr_number: int, head_sha: str, env: dict[str, str]) -> bool:
    """Whether a reviewer App's latest verdict on this head requests changes.

    Checked before asking for a re-review so a completed contract on a PR
    nobody has rejected does not spend a slot of the review budget.
    """
    reviews = _gh_json(
        ["api", f"repos/{{owner}}/{{repo}}/pulls/{pr_number}/reviews", "--paginate"],
        env,
    )
    if not isinstance(reviews, list):
        return False
    latest: dict[str, dict[str, object]] = {}
    for review in reviews:
        if not isinstance(review, dict):
            continue
        user = review.get("user")
        login = str(user.get("login", "")) if isinstance(user, dict) else ""
        if login not in REVIEWER_BOTS:
            continue
        if str(review.get("commit_id", "")) != head_sha:
            continue
        state = str(review.get("state", "")).upper()
        if state == "COMMENTED":
            continue
        current = latest.get(login)
        if current is None or str(review.get("submitted_at", "")) >= str(
            current.get("submitted_at", "")
        ):
            latest[login] = review
    return any(
        str(review.get("state", "")).upper() == CHANGES_REQUESTED
        for review in latest.values()
    )


def request_fresh_review(pr_number: int, env: dict[str, str]) -> None:
    """Ask the review lane to look again now that the contract is complete.

    The lane this runs in writes the PR body with GITHUB_TOKEN, and GitHub
    suppresses `pull_request: edited` runs caused by that token -- so the
    completion that satisfies a reviewer's objection generates no event at
    all, and the rejection stays blocking with nothing to clear it (#1379).
    Dispatching is the only way the news travels. It is a request, not a
    grant: factory-review.py re-derives from live PR state whether the
    standing rejection is actually refreshable.
    """
    if _gh(
        ["workflow", "run", REVIEW_WORKFLOW, "-f", f"pr_number={pr_number}"],
        env,
    ):
        log(f"PR #{pr_number}: requested a fresh counterpart review")
    else:
        log(f"PR #{pr_number}: could not request a fresh counterpart review")


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

    updates: dict[int, dict[str, object]] = {}
    verified: dict[int, dict[str, object]] = {}
    if (shared := colliding_indexes(entries)):
        # Two entries at one index are two answers to one requirement, and
        # which of them a verdict belongs to is decided by the order they
        # happen to be written in. Neither is acted on: nothing is verified,
        # nothing is written, and the label stays (#1778, round 2).
        log(
            f"PR #{pr_number}: evidence entries share index(es) "
            f"{', '.join(str(index) for index in shared)}; leaving the contract for the author"
        )
    else:
        recorded_status = {
            index: (
                str(at[0].get("status", "")).strip(),
                str(at[0].get("verified_head_sha", "")).strip(),
            )
            for index, at in entries_by_index(entries).items()
            if len(at) == 1
        }
        for index, check_name in ci_entries_needing_verification(entries, head_sha):
            runs = check_runs_for(check_name, head_sha, env)
            update = entry_update_for_check_run(
                check_name,
                head_sha,
                latest_completed_run(runs),
                # None means the lookup itself failed, which says nothing about
                # whether the check exists -- only an answered query that came
                # back empty does.
                check_known=runs is None or bool(runs),
            )
            if verdict_is_definite(runs):
                updates[index] = update
                verified[index] = update
                continue
            # An indefinite answer says nothing about the check, so it cannot
            # unsay a completion. The entry keeps what it records and is not
            # rewritten; it is absent from `verified`, so the label stays.
            status, recorded_sha = recorded_status.get(index, ("", ""))
            if not (status == "complete" and recorded_sha == head_sha):
                updates[index] = update
        if updates:
            updated_body = _apply_ci_updates(pr_number, head_sha, body, updates, env)
            if updated_body is None:
                return
            body = updated_body
            # The same narrowing the write makes: an update whose target index
            # no longer names the check it was computed for did not land, so
            # it may not count toward the clear either (#1778, round 2).
            verified = {
                index: update
                for index, update in _updates_targeting_unchanged_entries(body, verified).items()
            }

    # The transition question, and it takes the RECORDED reading on purpose.
    # It asks whether the body already looked complete before this run, and
    # its only consequence is whether a review is requested -- so reading the
    # entries as recorded can suppress a request and can never clear a label.
    # Reading it the verified way instead would make every check suite on a
    # finished pull request a fresh transition and spend a slot of the review
    # budget on each (#1778).
    was_complete = _recorded_contract_is_complete(entries, head_sha)
    now_complete = should_clear_blocked_label(
        evidence_entries(body), head_sha, verified=verified
    )
    label_names = {
        str(label.get("name", ""))
        for label in pr.get("labels", [])
        if isinstance(label, dict)
    }
    if BLOCKED_EVIDENCE_LABEL in label_names and now_complete:
        if blocked_label_applied_by_factory(pr_number, env):
            if _gh(
                ["pr", "edit", str(pr_number), "--remove-label", BLOCKED_EVIDENCE_LABEL],
                env,
            ):
                log(f"PR #{pr_number}: cleared machine-applied {BLOCKED_EVIDENCE_LABEL}")
                label_names.discard(BLOCKED_EVIDENCE_LABEL)
        else:
            log(
                f"PR #{pr_number}: {BLOCKED_EVIDENCE_LABEL} was not machine-applied; "
                "leaving for the owner"
            )

    # Only on the transition, and only once the PR would actually pass: a
    # re-review of a PR still carrying a blocking label would be refused
    # downstream anyway, and asking for it would spend budget for nothing.
    if was_complete or not now_complete:
        return
    if any(name.startswith("blocked:") for name in label_names):
        return
    if standing_rejection(pr_number, head_sha, env):
        request_fresh_review(pr_number, env)


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
