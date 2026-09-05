"""Evidence parsing, reconciliation, and delta computation."""

from __future__ import annotations

import json
import re
import shlex
import sys

from _helpers import (
    GITHUB_API_TIMEOUT,
    REPO_ROOT,
    has_markdown_section,
    insert_markdown_section,
    log,
    markdown_section,
    run_optional,
    strip_markdown_section,
)

# An item's own text carries em-dashes as a matter of house style, so a
# non-greedy item group ends the item at its first internal em-dash and makes a
# correctly authored item impossible to write. Splitting is anchored on the
# contract wherever the requested items are in hand: the candidate split whose
# item IS a requested item wins, so neither half's internal punctuation can
# terminate the item. Without that anchor the last separator wins, and the
# ASCII `--` this module renders outranks a dash character.
EVIDENCE_STATUS_PREFIX_RE = re.compile(
    r"^- \[(?P<status>complete|blocked|pending-ci)\] (?P<rest>.+)$"
)
EVIDENCE_SEPARATOR_RE = re.compile(r"\s+(?:--|—|–)\s+")
EVIDENCE_ASCII_SEPARATOR_RE = re.compile(r"\s+--\s+")
EVIDENCE_STATUS_LINE_RE = re.compile(
    r"^- \[(?P<status>complete|blocked|pending-ci)\] (?P<item>.+)\s+(?:--|—|–)\s+(?P<detail>.+)$"
)
# A bare index is the structured-update key, not an item name. Parsed as one it
# silently becomes an entry no requested item can match -- unless the contract
# really does ask for it, which the requested items settle.
NUMERIC_EVIDENCE_ITEM_RE = re.compile(r"#?\d+\.?")
# An indented line under a bullet continues it, unless it opens a block of its
# own: another bullet, an ordered item, a quote, or a fence.
MARKDOWN_BLOCK_OPENER_RE = re.compile(r"(?:[-*+]\s|\d+[.)]\s|>|```|~~~)")
EVIDENCE_METADATA_RE = re.compile(
    r"^<!-- evidence-status:v(?P<version>[^\n]+)\n(?P<payload>.*?)\n-->[ \t]*(?:\n|$)",
    re.MULTILINE | re.DOTALL,
)
STRUCTURED_EVIDENCE_UPDATE_RE = re.compile(
    r"^(?P<index>\d+)\s*--\s*(?P<detail>.+)$"
)
EVIDENCE_METADATA_VERSION = 1
EVIDENCE_FALLBACK_SENTENCE = "Follow the repo evidence bar for the touched surfaces."
SWIFT_TEST_NO_MATCH_TEXT = "No matching test cases were run"
VISUAL_EVIDENCE_RE = re.compile(
    r"\b(?:screenshots?|screen recordings?|visual (?:proof|evidence)|"
    r"(?:ui|interface|screen|window) captures?|before/after (?:images?|screenshots?))\b",
    re.IGNORECASE,
)
# A `ci` item names one check in backticks and asserts it is green. Two
# shapes are accepted, both requiring a CI keyword somewhere in the item:
#
#   `Lint, Test, Build` green on the PR head      -- name, then "green"
#   `check-links` check passes on the PR head     -- name, then a CI noun,
#                                                    then a pass verdict
#
# The second shape exists because "green" is not how most people write it,
# but its verdict words are ordinary English ("passes", "succeeded") and would
# match almost any backticked token without the noun binding them. Compare
# "`pnpm check` passes locally" or "the CI regression in `isValidRepoFullName`
# passes its new cases": neither names a check, and a `ci` entry naming a check
# that does not exist never completes -- strictly worse than the `other` it
# replaced. Name-after-verdict phrasing ("job green ... (`someFunction`
# cases)") does not classify for the same reason.
CI_EVIDENCE_NOUN = r"check|job|workflow|suite|lane|run"
CI_EVIDENCE_PASS = r"pass(?:es|ing|ed)?|succeed(?:s|ing|ed)?|success(?:ful)?"
CI_EVIDENCE_NAME_RES = (
    re.compile(r"(?i)`(?P<check>[^`]+)`[^`]*\bgreen\b"),
    re.compile(
        rf"(?i)`(?P<check>[^`]+)`\s+(?:{CI_EVIDENCE_NOUN})\b[^`]{{0,24}}?"
        rf"\b(?:{CI_EVIDENCE_PASS})\b"
    ),
)
CI_EVIDENCE_KEYWORD_RE = re.compile(r"(?i)\b(?:ci|check|workflow|job)\b")
# An explicit owner directive outranks every mechanical kind. Reading "shows X
# in the PR diff (owner-attested)" as diff-verifiable would be silently
# reassigning authority the author took the trouble to name; if the contract
# is wrong, the fix is to correct the issue text. Nothing classified `other`
# today changes because of this -- it only stops future widening from
# overriding an author who said who should sign.
OWNER_ATTESTED_RE = re.compile(
    r"(?i)owner[- ]attest\w*"
    r"|\b(?:owner|maintainer)\b[^\n]{0,24}?"
    r"\b(?:attest\w*|confirm\w*|verif\w*|approv\w*|sign[- ]?off|signs? off"
    r"|judg\w*|decid\w*|agree\w*)\b"
)
# A `diff` item asserts something a reader confirms by reading the diff.
# Completion is the counterpart review itself, bound to the review URL and
# head SHA, so a reviewer always closes it -- which makes this the safer
# direction to widen. The #1377 dogfood run parked a two-line docs change on
# the owner because "shows the link in the PR diff" matched none of the
# original phrasings, though the diff was the entire proof.
#
# The verbs bind tightly to "in the diff" rather than floating: "the owner
# must be present for the sign-off described in the diff" is not a diff
# assertion, and neither is a sentence that mentions the diff only after its
# real claim. A multi-clause item whose diff phrase is a subclause can still
# classify -- the same is true of the phrasings that predate this -- but the
# reviewer completing it reads the item text, so the assertion is not
# unexamined.
DIFF_EVIDENCE_RE = re.compile(
    r"(?i)^diff:"
    r"|(?:readable|visible|apparent|evident|confirmable) (?:from|in) the (?:pr )?diff"
    r"|verifiable by reading the (?:pr )?diff"
    r"|the (?:pr )?diff (?:shows|proves|demonstrates|contains|includes)"
    r"|\b(?:shows?|contains?|includes?|appears?)\b[^\n]{0,60}?\bin the (?:pr )?diff\b"
)
# Kinds the self-hosted macOS evidence lane can gather; `ci` and `diff`
# complete through the verifier workflow and review lane instead (#1120).
MACOS_EVIDENCE_KINDS = frozenset({"test", "build", "screenshot"})
EVENT_COMPLETED_KINDS = frozenset({"ci", "diff"})
SAFE_CANDIDATE_ENV_KEYS = {
    "CI",
    "COLORTERM",
    "HOME",
    "LANG",
    "LC_ALL",
    "LOGNAME",
    "NO_COLOR",
    "PATH",
    "SHELL",
    "TEMP",
    "TERM",
    "TMP",
    "TMPDIR",
    "TZ",
    "USER",
    "XDG_CACHE_HOME",
}


def split_evidence_status_line(
    line: str,
    requested_evidence: list[str] | None = None,
) -> tuple[str, str, str] | None:
    """`(status, item, detail)` for one `## Evidence Status` line, or None.

    Every separator on the line is a candidate split. The one that wins is the
    one whose item IS a requested item, so an em-dash inside either half cannot
    terminate the item. Absent the contract the last separator wins, and an
    ASCII `--` -- the form this module renders -- outranks a dash character.
    """
    prefix = EVIDENCE_STATUS_PREFIX_RE.match(line)
    if not prefix:
        return None
    rest = prefix.group("rest")
    status = prefix.group("status")
    candidates = [
        (rest[: separator.start()].strip(), rest[separator.end() :].strip(), separator.group())
        for separator in EVIDENCE_SEPARATOR_RE.finditer(rest)
    ]
    candidates = [row for row in candidates if row[0] and row[1]]
    if not candidates:
        return None
    if requested_evidence:
        wanted = {_normalize_evidence_key(item) for item in requested_evidence}
        for item, detail, _ in reversed(candidates):
            if _normalize_evidence_key(item) in wanted:
                return status, item, detail
    ascii_split = [row for row in candidates if "--" in row[2]]
    item, detail, _ = (ascii_split or candidates)[-1]
    return status, item, detail


def _is_requested_item(item: str, requested_evidence: list[str] | None) -> bool:
    if not requested_evidence:
        return False
    key = _normalize_evidence_key(item)
    return any(_normalize_evidence_key(other) == key for other in requested_evidence)


def is_numeric_evidence_item(item: str) -> bool:
    return NUMERIC_EVIDENCE_ITEM_RE.fullmatch(item.strip()) is not None


def _wrapped_bullets(section: str) -> list[str]:
    """One string per markdown bullet, with wrapped lines folded back in.

    A continuation line is indented and opens no block of its own: markdown
    reads it as part of the bullet above, so the contract reads it that way
    too. A blank line, a line at column zero, or an indented line that starts
    its own block ends the bullet, which keeps a following paragraph, nested
    list, quote, or fenced block out of the item text.
    """
    bullets: list[str] = []
    open_bullet = False
    for line in section.splitlines():
        stripped = line.strip()
        if stripped.startswith("- "):
            bullets.append(line[2:].strip())
            open_bullet = True
            continue
        if (
            open_bullet
            and stripped
            and line[:1].isspace()
            and not MARKDOWN_BLOCK_OPENER_RE.match(stripped)
        ):
            bullets[-1] = f"{bullets[-1]} {stripped}"
            continue
        open_bullet = False
    return bullets


def extract_requested_evidence(body: str) -> list[str]:
    evidence_section = markdown_section(body, "Requested Evidence")
    fallback_sentence = EVIDENCE_FALLBACK_SENTENCE.casefold()
    return [
        item
        for item in _wrapped_bullets(evidence_section)
        if item.lower() != "none" and item.casefold() != fallback_sentence
    ]


def _strip_evidence_metadata(body: str) -> str:
    stripped = EVIDENCE_METADATA_RE.sub("", body).strip()
    return re.sub(r"\n{3,}", "\n\n", stripped)


def _latest_evidence_metadata_match(body: str) -> re.Match[str] | None:
    matches = list(EVIDENCE_METADATA_RE.finditer(body))
    if not matches:
        return None
    return matches[-1]


def _extract_evidence_metadata(body: str) -> dict[str, object] | None:
    match = _latest_evidence_metadata_match(body)
    if not match:
        return None
    try:
        version = int(match.group("version"))
    except (TypeError, ValueError):
        return None
    if version != EVIDENCE_METADATA_VERSION:
        return None
    try:
        payload = json.loads(match.group("payload"))
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _insert_evidence_metadata(body: str, payload: dict[str, object]) -> str:
    metadata = (
        f"<!-- evidence-status:v{EVIDENCE_METADATA_VERSION}\n"
        f"{json.dumps(payload, indent=2, ensure_ascii=False)}\n"
        f"-->"
    )
    cleaned = _strip_evidence_metadata(body).strip()
    pattern = r"(?m)^## Evidence Status\s*$"
    if re.search(pattern, cleaned):
        return re.sub(pattern, f"{metadata}\n\n## Evidence Status", cleaned, count=1)
    if cleaned:
        return f"{cleaned}\n\n{metadata}"
    return metadata


def _stored_item_matches(stored_item: str, item: str) -> bool:
    """Does metadata written for this index still describe this requested item?

    A body rendered before wrapped bullets were joined stored the item's first
    physical line, which is the joined item cut at a fold. Accepting that keeps
    an in-flight PR's metadata valid instead of invalidating every entry on it.
    """
    stored = stored_item.strip()
    return stored == item or (bool(stored) and item.startswith(f"{stored} "))


def _explicit_evidence_contract(requested_evidence: list[str]) -> bool:
    return bool(requested_evidence)


def _structured_evidence_entries(
    body: str,
    requested_evidence: list[str],
) -> dict[str, object] | None:
    if not _explicit_evidence_contract(requested_evidence):
        return None
    match = _latest_evidence_metadata_match(body)
    if match is None:
        return None
    try:
        version = int(match.group("version"))
    except (TypeError, ValueError):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [f"metadata version '{match.group('version')}' is not a valid integer"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }
    if version != EVIDENCE_METADATA_VERSION:
        return None
    try:
        payload = json.loads(match.group("payload"))
    except json.JSONDecodeError as exc:
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [f"metadata payload is not valid JSON: {exc.msg}"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }
    if not isinstance(payload, dict):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": ["metadata payload must be a JSON object"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }
    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": ["metadata payload must contain an 'entries' list"],
            "duplicate_items": [],
            "source": "structured-invalid",
        }

    entries: dict[str, dict[str, str]] = {}
    duplicate_items: list[str] = []
    invalid_lines: list[str] = []
    for position, raw_entry in enumerate(raw_entries, start=1):
        if not isinstance(raw_entry, dict):
            invalid_lines.append(f"entry {position} is not an object")
            continue
        try:
            index = int(raw_entry["index"])
        except (KeyError, TypeError, ValueError):
            invalid_lines.append(f"entry {position} is missing a valid integer index")
            continue
        if index < 1 or index > len(requested_evidence):
            invalid_lines.append(
                f"entry {position} index {index} is out of range for {len(requested_evidence)} requested items"
            )
            continue
        status = str(raw_entry.get("status", "")).strip()
        detail = str(raw_entry.get("detail", "")).strip()
        if status not in {"complete", "blocked", "pending-ci"}:
            invalid_lines.append(f"entry {position} has invalid status '{status}'")
            continue
        if not detail:
            invalid_lines.append(f"entry {position} has an empty detail")
            continue
        item = requested_evidence[index - 1]
        stored_item = raw_entry.get("item")
        if stored_item is not None and not _stored_item_matches(str(stored_item), item):
            invalid_lines.append(
                f"entry {position} item does not match requested evidence index {index}"
            )
            continue
        if item in entries:
            duplicate_items.append(item)
            continue
        entries[item] = {
            "status": status,
            "detail": detail,
        }

    return {
        "section_present": has_markdown_section(body, "Evidence Status"),
        "entries": {} if invalid_lines else entries,
        "invalid_lines": invalid_lines,
        "duplicate_items": duplicate_items,
        "source": "structured-invalid" if invalid_lines else "structured",
    }


def extract_evidence_status_entries(
    body: str,
    requested_evidence: list[str] | None = None,
) -> dict[str, object]:
    section_present = has_markdown_section(body, "Evidence Status")
    evidence_section = markdown_section(body, "Evidence Status")
    entries: dict[str, dict[str, str]] = {}
    invalid_lines: list[str] = []
    duplicate_items: list[str] = []

    for raw_line in evidence_section.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if not line.startswith("- "):
            invalid_lines.append(line)
            continue
        split = split_evidence_status_line(line, requested_evidence)
        if not split:
            invalid_lines.append(line)
            continue
        status, item, detail = split
        # A bare index is the structured-update key. Read as an item name it
        # becomes an entry nothing can match -- unless the contract asks for
        # exactly that, which only the requested items can say.
        if is_numeric_evidence_item(item) and not _is_requested_item(item, requested_evidence):
            invalid_lines.append(line)
            continue
        if item in entries:
            duplicate_items.append(item)
            continue
        entries[item] = {
            "status": status,
            "detail": detail,
        }

    return {
        "section_present": section_present,
        "entries": entries,
        "invalid_lines": invalid_lines,
        "duplicate_items": duplicate_items,
        "source": "markdown",
    }


def _normalize_evidence_key(text: str) -> str:
    t = text.strip().strip("`").strip()
    t = re.sub(r"\s+", " ", t).casefold()
    t = t.rstrip(".,;:)")
    return t


def _match_evidence_entry(
    requested_item: str,
    entries: dict[str, dict[str, str]],
) -> str | None:
    if requested_item in entries:
        return requested_item
    norm_req = _normalize_evidence_key(requested_item)
    for entry_key in entries:
        if _normalize_evidence_key(entry_key) == norm_req:
            return entry_key
    req_words = set(norm_req.split())
    for entry_key in entries:
        entry_words = set(_normalize_evidence_key(entry_key).split())
        if req_words and entry_words:
            overlap = len(req_words & entry_words) / len(req_words)
            if overlap >= 0.7:
                return entry_key
    return None


def evaluate_evidence_accounting(body: str, requested_evidence: list[str]) -> dict[str, object]:
    if not _explicit_evidence_contract(requested_evidence):
        return {
            "section_present": has_markdown_section(body, "Evidence Status"),
            "entries": {},
            "invalid_lines": [],
            "duplicate_items": [],
            "source": "none",
            "missing_items": [],
            "blocked_items": [],
            "pending_ci_items": [],
            "complete_items": [],
            "unexpected_items": [],
            "blocked_on_evidence": "blocked on evidence" in body.casefold(),
            "contract_required": False,
        }

    # _structured_evidence_entries returns a non-None dict even when metadata is malformed
    # (source="structured-invalid"). The `or` only triggers when there is no hidden metadata
    # at all, falling back to markdown parsing.
    parsed = _structured_evidence_entries(
        body, requested_evidence
    ) or extract_evidence_status_entries(body, requested_evidence)
    entries = parsed["entries"]

    matched: dict[str, str] = {}
    if parsed["source"] == "structured":
        matched = {
            item: item
            for item in requested_evidence
            if item in entries
        }
    else:
        for item in requested_evidence:
            match = _match_evidence_entry(item, entries)
            if match is not None:
                matched[item] = match

    missing_items = [item for item in requested_evidence if item not in matched]
    blocked_items = [
        item
        for item in requested_evidence
        if item in matched and entries[matched[item]]["status"] == "blocked"
    ]
    pending_ci_items = [
        item
        for item in requested_evidence
        if item in matched and entries[matched[item]]["status"] == "pending-ci"
    ]
    complete_items = [
        item
        for item in requested_evidence
        if item in matched and entries[matched[item]]["status"] == "complete"
    ]
    matched_keys = set(matched.values())
    unexpected_items = [item for item in entries if item not in matched_keys]
    return {
        **parsed,
        "missing_items": missing_items,
        "blocked_items": blocked_items,
        "pending_ci_items": pending_ci_items,
        "complete_items": complete_items,
        "unexpected_items": unexpected_items,
        "blocked_on_evidence": "blocked on evidence" in body.casefold(),
        "contract_required": True,
    }


def _truncate(text: str, max_len: int = 80) -> str:
    text = str(text)
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def _format_malformed_preview(invalid_lines: list[object], max_shown: int = 2) -> str:
    parts: list[str] = []
    for i, line in enumerate(invalid_lines[:max_shown]):
        parts.append(f'line {i + 1}: "{_truncate(str(line))}"')
    remaining = len(invalid_lines) - max_shown
    if remaining > 0:
        parts.append(f"{remaining} more")
    return "(" + "; ".join(parts) + ")"


def _format_missing_preview(
    missing_items: list[object], requested_evidence: list[str], max_shown: int = 3,
) -> str:
    parts: list[str] = []
    for item in missing_items[:max_shown]:
        item_str = str(item)
        try:
            idx = requested_evidence.index(item_str) + 1
        except ValueError:
            idx = "?"
        parts.append(f'[{idx}] "{_truncate(item_str)}"')
    remaining = len(missing_items) - max_shown
    if remaining > 0:
        parts.append(f"{remaining} more")
    return "; ".join(parts)


def validate_evidence_accounting(body: str, requested_evidence: list[str]) -> tuple[dict[str, object], list[str]]:
    if not requested_evidence:
        return evaluate_evidence_accounting(body, []), []
    accounting = evaluate_evidence_accounting(body, requested_evidence)
    errors: list[str] = []
    if not accounting["section_present"]:
        errors.append("missing required '## Evidence Status' section")
    invalid_lines = accounting["invalid_lines"]
    if invalid_lines:
        preview = _format_malformed_preview(invalid_lines)
        if accounting["source"] == "structured-invalid":
            errors.append(f"malformed hidden evidence metadata: {preview}")
        else:
            errors.append(
                "malformed Evidence Status entries; expected "
                "'- [complete|blocked|pending-ci] <requested_evidence item> -- <proof note>' "
                f"{preview}"
            )
    duplicate_items = accounting["duplicate_items"]
    if duplicate_items:
        parts = [f'"{_truncate(str(item))}"' for item in duplicate_items[:3]]
        remaining = len(duplicate_items) - 3
        if remaining > 0:
            parts.append(f"{remaining} more")
        preview = "; ".join(parts)
        errors.append(f"duplicate Evidence Status entries for: {preview}")
    missing_items = accounting["missing_items"]
    if missing_items:
        preview = _format_missing_preview(missing_items, requested_evidence)
        errors.append(
            "PR body must account for every requested evidence item exactly; "
            f"missing: {preview}"
        )
    if accounting["blocked_items"] and not accounting["blocked_on_evidence"]:
        errors.append(
            "blocked evidence entries require 'blocked on evidence' language in the Validation section"
        )
    if accounting["pending_ci_items"] and not accounting["blocked_on_evidence"]:
        errors.append(
            "pending-ci evidence entries require 'blocked on evidence' language in the Validation section"
        )
    return accounting, errors


def classify_evidence_error(error: str) -> str:
    if error.startswith("missing required '## Evidence Status'"):
        return "evidence_section_missing"
    if error.startswith("malformed Evidence Status entries"):
        return "evidence_format"
    if error.startswith("malformed hidden evidence metadata"):
        return "evidence_metadata"
    if error.startswith("duplicate Evidence Status entries"):
        return "evidence_duplicate"
    if "missing:" in error:
        return "evidence_missing"
    return "evidence_format"


def classify_evidence_errors(errors: list[str]) -> list[dict[str, str]]:
    return [{"category": classify_evidence_error(e), "message": e} for e in errors]


def parse_structured_evidence_updates(
    entries: object,
    *,
    requested_evidence: list[str],
    status: str,
    field_name: str,
    used_indexes: set[int],
) -> tuple[list[dict[str, object]], list[str]]:
    errors: list[str] = []
    parsed: list[dict[str, object]] = []
    if entries is None:
        return parsed, errors
    if not isinstance(entries, list):
        return parsed, [f"field '{field_name}' must be a list"]

    for raw_entry in entries:
        text = str(raw_entry).strip()
        match = STRUCTURED_EVIDENCE_UPDATE_RE.match(text)
        if not match:
            errors.append(
                f"{field_name} entries must use '<requested_evidence index> -- <proof note>' (got: {text})"
            )
            continue
        index = int(match.group("index"))
        if index < 1 or index > len(requested_evidence):
            errors.append(
                f"{field_name} index {index} is out of range for {len(requested_evidence)} requested evidence items"
            )
            continue
        if index in used_indexes:
            errors.append(f"requested evidence index {index} was listed more than once")
            continue
        used_indexes.add(index)
        parsed.append(
            {
                "index": index,
                "item": requested_evidence[index - 1],
                "status": status,
                "detail": match.group("detail").strip(),
            }
        )
    return parsed, errors


def render_execution_summary_body(
    summary_body: str,
    *,
    requested_evidence: list[str],
    evidence_complete: object,
    evidence_blocked: object,
    evidence_pending_ci: object,
) -> tuple[str, list[str]]:
    if not _explicit_evidence_contract(requested_evidence):
        return summary_body, []

    used_indexes: set[int] = set()
    complete_entries, errors = parse_structured_evidence_updates(
        evidence_complete,
        requested_evidence=requested_evidence,
        status="complete",
        field_name="evidence_complete",
        used_indexes=used_indexes,
    )
    blocked_entries, blocked_errors = parse_structured_evidence_updates(
        evidence_blocked,
        requested_evidence=requested_evidence,
        status="blocked",
        field_name="evidence_blocked",
        used_indexes=used_indexes,
    )
    pending_ci_entries, pending_ci_errors = parse_structured_evidence_updates(
        evidence_pending_ci,
        requested_evidence=requested_evidence,
        status="pending-ci",
        field_name="evidence_pending_ci",
        used_indexes=used_indexes,
    )
    errors.extend(blocked_errors)
    errors.extend(pending_ci_errors)
    if errors:
        return summary_body, errors

    evidence_map = {
        int(entry["index"]): entry
        for entry in complete_entries + blocked_entries + pending_ci_entries
    }
    evidence_lines = [
        f"- [{entry['status']}] {entry['item']} -- {entry['detail']}"
        for index, entry in sorted(evidence_map.items())
    ]
    structured_entries = [
        {
            "index": entry["index"],
            "item": entry["item"],
            "status": entry["status"],
            "detail": entry["detail"],
            "kind": _evidence_item_kind(str(entry["item"])),
        }
        for _, entry in sorted(evidence_map.items())
    ]

    rendered = insert_markdown_section(
        _strip_evidence_metadata(summary_body),
        "Evidence Status",
        "\n".join(evidence_lines),
        before_heading="Validation",
    )
    rendered = _insert_evidence_metadata(
        rendered,
        {
            "entries": structured_entries,
        },
    )
    blocked_like_entries = blocked_entries + pending_ci_entries
    if blocked_like_entries and "blocked on evidence" not in rendered.casefold():
        blocked_note = "; ".join(str(entry["detail"]) for entry in blocked_like_entries)
        validation = markdown_section(rendered, "Validation")
        if validation:
            validation = f"{validation.rstrip()}\n- blocked on evidence: {blocked_note}"
        else:
            validation = f"- blocked on evidence: {blocked_note}"
        rendered = insert_markdown_section(rendered, "Validation", validation, before_heading="Risks")
    return rendered, []


def review_evidence_gate_error(verdict: str, accounting: dict[str, object], errors: list[str]) -> str | None:
    if verdict == "request_changes":
        return None
    if errors:
        return "; ".join(errors)
    blocked_items = accounting["blocked_items"]
    if blocked_items:
        preview = "; ".join(str(item) for item in blocked_items[:3])
        return (
            "requested evidence is still blocked and review must stay in request_changes; "
            f"blocked: {preview}"
        )
    # Pending `diff` items do not block approve: the approving review IS the
    # verification act, and the review lane writes the completion (bound to
    # the review URL and head SHA) immediately after the approval lands.
    pending_ci_items = [
        item
        for item in accounting.get("pending_ci_items", [])
        if _evidence_item_kind(str(item)) != "diff"
    ]
    if pending_ci_items:
        preview = "; ".join(str(item) for item in pending_ci_items[:3])
        return (
            "requested evidence is pending CI and review must stay in request_changes; "
            f"pending-ci: {preview}"
        )
    return None


def _normalize_evidence_item(item: str) -> str:
    return item.strip().strip("`").strip()


def _ci_check_name(item: str) -> str | None:
    """The CI check an evidence item requires green on the PR head, or None.

    Fail-closed: CI-ish phrasing without an extractable backticked name
    stays kind `other` (blocked, owner follow-up) rather than guessing.
    """
    text = item.strip()
    if not CI_EVIDENCE_KEYWORD_RE.search(text):
        return None
    for pattern in CI_EVIDENCE_NAME_RES:
        match = pattern.search(text)
        if match is not None and match.group("check").strip():
            return match.group("check").strip()
    return None


def _is_owner_attested(item: str) -> bool:
    return OWNER_ATTESTED_RE.search(_normalize_evidence_item(item)) is not None


def _is_diff_evidence(item: str) -> bool:
    return DIFF_EVIDENCE_RE.search(_normalize_evidence_item(item)) is not None


def _evidence_item_kind(item: str) -> str:
    normalized = _normalize_evidence_item(item).casefold()
    if normalized.startswith("swift test"):
        return "test"
    if normalized.startswith("swift build"):
        return "build"
    if VISUAL_EVIDENCE_RE.search(normalized):
        return "screenshot"
    if _is_owner_attested(item):
        return "other"
    if _ci_check_name(item) is not None:
        return "ci"
    if _is_diff_evidence(item):
        return "diff"
    return "other"


def _needs_macos_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) in MACOS_EVIDENCE_KINDS for item in requested_evidence)


def _has_unautomatable_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) == "other" for item in requested_evidence)


def _needs_screenshot_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) == "screenshot" for item in requested_evidence)


def _extract_test_commands(requested_evidence: list[str]) -> list[str]:
    return [
        _normalize_evidence_item(item)
        for item in requested_evidence
        if _evidence_item_kind(item) == "test"
    ]


def synthesize_initial_execution_evidence(
    requested_evidence: list[str],
    *,
    visual_evidence_available: bool = True,
) -> tuple[list[str], list[str], list[str]]:
    evidence_complete: list[str] = []
    evidence_blocked: list[str] = []
    evidence_pending_ci: list[str] = []
    for index, item in enumerate(requested_evidence, start=1):
        normalized = _normalize_evidence_item(item)
        kind = _evidence_item_kind(item)
        if kind == "build":
            evidence_pending_ci.append(
                f"{index} -- self-hosted macOS evidence workflow will run `{normalized}` from the exact commit under review"
            )
        elif kind == "test":
            evidence_pending_ci.append(
                f"{index} -- self-hosted macOS evidence workflow will run `{normalized}` from the exact commit under review"
            )
        elif kind == "screenshot":
            if visual_evidence_available:
                evidence_pending_ci.append(
                    f"{index} -- self-hosted macOS evidence workflow will capture this evidence from the exact commit under review"
                )
            else:
                evidence_blocked.append(
                    f"{index} -- Xcode Cloud capture lane #1088 is not available; orchestrator or owner must provide the documented visual-evidence handshake"
                )
        elif kind == "ci":
            evidence_pending_ci.append(
                f"{index} -- named CI check `{_ci_check_name(item)}` must be green on the PR head; "
                "the factory evidence verifier completes this automatically when checks finish"
            )
        elif kind == "diff":
            evidence_pending_ci.append(
                f"{index} -- verifiable by reading the PR diff; completed by the counterpart review of the current head"
            )
        else:
            evidence_blocked.append(
                f"{index} -- automation cannot reconcile this evidence item automatically; owner follow-up required"
            )
    return evidence_complete, evidence_blocked, evidence_pending_ci


def safe_swift_test_command_args(command: str) -> list[str] | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None

    if parts == ["swift", "test"]:
        return parts

    if len(parts) == 4 and parts[:3] == ["swift", "test", "--filter"] and parts[3].strip():
        return parts

    if (
        len(parts) == 3
        and parts[:2] == ["swift", "test"]
        and parts[2].startswith("--filter=")
        and parts[2] != "--filter="
    ):
        return parts

    return None


def safe_swift_build_command_args(command: str) -> list[str] | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    return parts if parts == ["swift", "build"] else None


def sanitized_candidate_code_env(env: dict[str, str]) -> dict[str, str]:
    """Keep credentials out of commands that evaluate an agent-authored tree."""

    return {
        key: value
        for key, value in env.items()
        if key in SAFE_CANDIDATE_ENV_KEYS and value
    }


def _swift_test_filter_selector(command: str) -> str | None:
    parts = safe_swift_test_command_args(command)
    if parts is None or len(parts) < 3:
        return None

    if len(parts) == 4 and parts[2] == "--filter":
        return parts[3]
    if len(parts) == 3 and parts[2].startswith("--filter="):
        return parts[2].split("=", 1)[1]
    return None


def _selector_matches_test_list(selector: str, listed_tests: list[str]) -> bool:
    try:
        pattern = re.compile(selector)
    except re.error:
        return False
    return any(pattern.search(specifier) for specifier in listed_tests)


def _listed_swift_tests(env: dict[str, str]) -> list[str]:
    output = run_optional(
        ["swift", "test", "list"],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    return [
        line.strip()
        for line in output.splitlines()
        if line.strip() and "." in line and "/" in line
    ]


def validate_requested_test_commands(
    requested_evidence: list[str],
    env: dict[str, str],
) -> list[str]:
    commands = _extract_test_commands(requested_evidence)
    build_commands = [
        _normalize_evidence_item(item)
        for item in requested_evidence
        if _evidence_item_kind(item) == "build"
    ]
    errors = [
        "requested test evidence "
        f"`{command}` must use `swift test` or `swift test --filter <selector>`; "
        "extra flags and shell operators are not allowed"
        for command in commands
        if safe_swift_test_command_args(command) is None
    ]
    errors.extend(
        "requested build evidence "
        f"`{command}` must use exactly `swift build`; extra flags and shell operators are not allowed"
        for command in build_commands
        if safe_swift_build_command_args(command) is None
    )

    swift_filter_commands = [
        command
        for command in commands
        if _swift_test_filter_selector(command) is not None
    ]
    if not swift_filter_commands:
        return errors

    # Look up through the entrypoint module to allow mock.patch.object patching.
    _mod = sys.modules.get("run_contributor", sys.modules[__name__])
    listed_tests = _mod._listed_swift_tests(sanitized_candidate_code_env(env))
    if not listed_tests:
        log(
            "skipping `swift test list` evidence selector preflight because no Swift Testing "
            "specifiers were returned; the project may need to build first"
        )
        return errors

    for command in swift_filter_commands:
        selector = _swift_test_filter_selector(command)
        if selector is None:
            continue
        if not _selector_matches_test_list(selector, listed_tests):
            errors.append(
                f"requested test evidence `{command}` does not match any `swift test list` specifier; "
                "use a target-qualified selector such as "
                "`swift test --filter 'WorkspaceManagerTests.WorkspaceProviderTests'`"
            )
    return errors


def _format_uploaded_evidence_links(uploaded_urls: list[tuple[str, str]]) -> str:
    return ", ".join(f"[{label}]({url})" for label, url in uploaded_urls)


def _test_output_by_command(test_output: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_command: str | None = None
    for raw_line in test_output.splitlines():
        if raw_line.startswith("$ "):
            current_command = raw_line[2:].strip()
            sections.setdefault(current_command, [])
            continue
        if current_command is not None:
            sections[current_command].append(raw_line)
    return {
        command: "\n".join(lines)
        for command, lines in sections.items()
    }


def _test_output_has_no_matching_tests(command: str, test_output: str) -> bool:
    if not test_output:
        return False
    command_output = _test_output_by_command(test_output).get(command)
    if command_output is None:
        return SWIFT_TEST_NO_MATCH_TEXT in test_output
    return SWIFT_TEST_NO_MATCH_TEXT in command_output


def _pending_ci_resolution(
    item: str,
    *,
    build_succeeded: bool,
    tests_succeeded: bool,
    smoke_succeeded: bool,
    test_output: str = "",
    screenshot_upload_succeeded: bool = False,
    screenshot_urls: list[tuple[str, str]] | None = None,
    text_upload_required: bool = False,
    text_upload_succeeded: bool = False,
    text_urls: list[tuple[str, str]] | None = None,
) -> tuple[str, str]:
    kind = _evidence_item_kind(item)
    normalized = _normalize_evidence_item(item)
    uploaded_screenshot_urls = screenshot_urls or []
    uploaded_text_urls = text_urls or []

    def text_link(prefix: str) -> str | None:
        match = next(
            ((label, url) for label, url in uploaded_text_urls if label.startswith(prefix)),
            None,
        )
        if match is None:
            return None
        label, url = match
        return f"[{label}]({url})"

    if kind == "build":
        if build_succeeded:
            if text_upload_required:
                link = text_link("build-output")
                if text_upload_succeeded and link:
                    return "complete", f"`swift build` succeeded on self-hosted macOS CI: {link}"
                return "blocked", "self-hosted macOS CI build log upload failed"
            return "complete", "`swift build` succeeded on self-hosted macOS CI"
        return "blocked", "self-hosted macOS CI `swift build` failed; see workflow logs"
    if kind == "test":
        if tests_succeeded:
            if _test_output_has_no_matching_tests(normalized, test_output):
                return "blocked", f"self-hosted macOS CI `{normalized}` matched no tests; see test-output.txt"
            if text_upload_required:
                link = text_link("test-output")
                if text_upload_succeeded and link:
                    return "complete", f"`{normalized}` succeeded on self-hosted macOS CI: {link}"
                return "blocked", "self-hosted macOS CI test log upload failed"
            return "complete", f"`{normalized}` succeeded on self-hosted macOS CI"
        return "blocked", f"self-hosted macOS CI `{normalized}` failed; see test-output.txt"
    if kind == "screenshot":
        if smoke_succeeded:
            if screenshot_upload_succeeded and uploaded_screenshot_urls:
                links = _format_uploaded_evidence_links(uploaded_screenshot_urls)
                return "complete", f"captured on self-hosted macOS CI: {links}"
            if screenshot_upload_succeeded:
                return "blocked", "self-hosted macOS CI captured screenshots but no R2 URLs were recorded; see workflow artifacts"
            return "blocked", "self-hosted macOS CI captured screenshots but R2 upload failed; see workflow artifacts"
        return "blocked", "self-hosted macOS CI screenshot capture failed; see dev-smoke-output.txt"
    return "blocked", "self-hosted macOS CI cannot reconcile this evidence item automatically"


def _render_structured_entries(body: str, updated_entries: list[object]) -> str:
    """Re-render the Evidence Status section and hidden metadata from entries."""
    rendered_entries: list[dict[str, object]] = []
    for entry in updated_entries:
        if not isinstance(entry, dict):
            continue
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError):
            continue
        item = str(entry.get("item", "")).strip()
        status = str(entry.get("status", "")).strip()
        detail = str(entry.get("detail", "")).strip()
        if index < 1 or not item or status not in {"complete", "blocked", "pending-ci"} or not detail:
            continue
        rendered_entries.append(
            {
                "index": index,
                "item": item,
                "status": status,
                "detail": detail,
            }
        )

    if rendered_entries:
        reconciled = insert_markdown_section(
            _strip_evidence_metadata(body),
            "Evidence Status",
            "\n".join(
                f"- [{entry['status']}] {entry['item']} -- {entry['detail']}"
                for entry in sorted(rendered_entries, key=lambda entry: int(entry["index"]))
            ),
            before_heading="Validation",
        )
    else:
        reconciled = body
    reconciled = _insert_evidence_metadata(
        reconciled,
        {
            "entries": updated_entries,
        },
    )
    if body.endswith("\n"):
        reconciled += "\n"
    return reconciled


def update_evidence_entries(body: str, updates: dict[int, dict[str, object]]) -> str:
    """Apply per-index status/detail updates to structured evidence entries.

    Trusted-lane writers (the CI evidence verifier, review-time completion)
    use this to flip entries without hand-editing markdown. Fail-closed:
    bodies without valid structured metadata, unknown indexes, and invalid
    statuses are left unchanged.
    """
    metadata = _extract_evidence_metadata(body)
    if not isinstance(metadata, dict) or not isinstance(metadata.get("entries"), list):
        return body
    updated_entries: list[object] = []
    changed = False
    for raw_entry in metadata["entries"]:
        if not isinstance(raw_entry, dict):
            updated_entries.append(raw_entry)
            continue
        entry = dict(raw_entry)
        try:
            index = int(entry["index"])
        except (KeyError, TypeError, ValueError):
            updated_entries.append(entry)
            continue
        update = updates.get(index)
        if update is not None:
            status = str(update.get("status", entry.get("status", ""))).strip()
            detail = str(update.get("detail", entry.get("detail", ""))).strip()
            if status in {"complete", "blocked", "pending-ci"} and detail:
                entry["status"] = status
                entry["detail"] = detail
                for key in ("kind", "check_name", "verified_head_sha", "proof_url"):
                    if key in update:
                        entry[key] = update[key]
                changed = True
        updated_entries.append(entry)
    if not changed:
        return body
    return _render_structured_entries(body, updated_entries)


def check_runs_for(
    check_name: str,
    head_sha: str,
    env: dict[str, str],
) -> list[dict[str, object]] | None:
    """Every run of a named check on a commit, or None if the query failed.

    The empty list and None mean different things, and callers act on the
    difference: an empty list says GitHub knows of no check by that name on
    this head — usually a wrong name in the evidence item, which would
    otherwise wait forever — while None says the lookup itself did not
    resolve. Requires GH_REPO or a repo-resolving checkout for `gh api`.
    """
    raw = run_optional(
        [
            "gh", "api",
            "-X", "GET",
            f"repos/{{owner}}/{{repo}}/commits/{head_sha}/check-runs",
            "-f", f"check_name={check_name}",
            "-f", "filter=latest",
        ],
        timeout=GITHUB_API_TIMEOUT,
        cwd=REPO_ROOT,
        env=env,
        default="",
    )
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    runs = payload.get("check_runs") if isinstance(payload, dict) else None
    if not isinstance(runs, list):
        return None
    return [run for run in runs if isinstance(run, dict)]


def latest_completed_check_run(
    check_name: str,
    head_sha: str,
    env: dict[str, str],
) -> dict[str, object] | None:
    """Most recently completed run of a named check on a commit, or None.

    Queries live check-run state so callers never trust conclusions recorded
    in a PR body.
    """
    runs = check_runs_for(check_name, head_sha, env)
    completed = [
        run for run in runs or [] if str(run.get("status", "")) == "completed"
    ]
    if not completed:
        return None
    return max(completed, key=lambda run: str(run.get("completed_at", "")))


def reconcile_pending_ci_evidence(
    body: str,
    *,
    build_succeeded: bool,
    tests_succeeded: bool,
    smoke_succeeded: bool,
    test_output: str = "",
    screenshot_upload_succeeded: bool = False,
    screenshot_urls: list[tuple[str, str]] | None = None,
    text_upload_required: bool = False,
    text_upload_succeeded: bool = False,
    text_urls: list[tuple[str, str]] | None = None,
) -> str:
    """Resolve pending-ci evidence lines after the macOS evidence job finishes.

    `ci` and `diff` kind entries are left untouched: they complete through the
    evidence verifier workflow and the review lane, not the macOS lane.
    """
    metadata = _extract_evidence_metadata(body)
    if isinstance(metadata, dict) and isinstance(metadata.get("entries"), list):
        updated_entries: list[object] = []
        for raw_entry in metadata["entries"]:
            if not isinstance(raw_entry, dict):
                updated_entries.append(raw_entry)
                continue
            entry = dict(raw_entry)
            item = str(entry.get("item", "")).strip()
            if (
                str(entry.get("status", "")).strip() == "pending-ci"
                and _evidence_item_kind(item) not in EVENT_COMPLETED_KINDS
            ):
                status, detail = _pending_ci_resolution(
                    item,
                    build_succeeded=build_succeeded,
                    tests_succeeded=tests_succeeded,
                    smoke_succeeded=smoke_succeeded,
                    test_output=test_output,
                    screenshot_upload_succeeded=screenshot_upload_succeeded,
                    screenshot_urls=screenshot_urls,
                    text_upload_required=text_upload_required,
                    text_upload_succeeded=text_upload_succeeded,
                    text_urls=text_urls,
                )
                entry["status"] = status
                entry["detail"] = detail
            updated_entries.append(entry)
        return _render_structured_entries(body, updated_entries)

    lines = body.splitlines()
    updated: list[str] = []
    in_evidence_status = False

    for line in lines:
        if line.startswith("## "):
            in_evidence_status = line.strip() == "## Evidence Status"
            updated.append(line)
            continue
        if in_evidence_status:
            split = split_evidence_status_line(line)
            if (
                split
                and split[0] == "pending-ci"
                and not is_numeric_evidence_item(split[1])
                and _evidence_item_kind(split[1]) not in EVENT_COMPLETED_KINDS
            ):
                item = split[1]
                status, detail = _pending_ci_resolution(
                    item,
                    build_succeeded=build_succeeded,
                    tests_succeeded=tests_succeeded,
                    smoke_succeeded=smoke_succeeded,
                    test_output=test_output,
                    screenshot_upload_succeeded=screenshot_upload_succeeded,
                    screenshot_urls=screenshot_urls,
                    text_upload_required=text_upload_required,
                    text_upload_succeeded=text_upload_succeeded,
                    text_urls=text_urls,
                )
                updated.append(f"- [{status}] {item} -- {detail}")
                continue
        updated.append(line)

    reconciled = "\n".join(updated)
    if body.endswith("\n"):
        reconciled += "\n"
    return reconciled


def summarize_requested_evidence(requested_evidence: list[str]) -> str:
    if not requested_evidence:
        return "Evidence contract: none"
    preview = requested_evidence[:2]
    suffix = " ..." if len(requested_evidence) > 2 else ""
    return "; ".join(preview) + suffix


def format_requested_evidence_numbered(
    requested_evidence: list[str],
    *,
    indent: str,
) -> str:
    if not requested_evidence:
        return f"{indent}Evidence contract: none"
    lines = [f"{indent}Requested evidence by index:"]
    for index, item in enumerate(requested_evidence, start=1):
        lines.append(f"{indent}  [{index}] {item}")
    return "\n".join(lines)


def summarize_evidence_accounting_by_index(accounting: dict[str, object], requested_evidence: list[str]) -> str:
    if not requested_evidence:
        return "Evidence contract: none"

    def indexes(items: list[str]) -> str:
        if not items:
            return "-"
        positions = [
            str(index)
            for index, item in enumerate(requested_evidence, start=1)
            if item in items
        ]
        return ", ".join(positions) if positions else "-"

    summary = (
        "Current PR evidence: "
        f"complete [{indexes(list(accounting['complete_items']))}], "
        f"blocked [{indexes(list(accounting['blocked_items']))}], "
        f"missing [{indexes(list(accounting['missing_items']))}]"
    )
    malformed = accounting.get("invalid_lines", [])
    if accounting.get("source") == "markdown":
        return f"{summary}, malformed {len(malformed)}"
    if accounting.get("source") == "structured-invalid":
        return f"{summary}, metadata invalid"
    return summary
