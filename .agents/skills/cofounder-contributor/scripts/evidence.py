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

EVIDENCE_STATUS_LINE_RE = re.compile(
    r"^- \[(?P<status>complete|blocked|pending-ci)\] (?P<item>.+?)\s+(?:--|—|–)\s+(?P<detail>.+)$"
)
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


def extract_requested_evidence(body: str) -> list[str]:
    evidence_section = markdown_section(body, "Requested Evidence")
    fallback_sentence = EVIDENCE_FALLBACK_SENTENCE.casefold()
    return [
        line[2:].strip()
        for line in evidence_section.splitlines()
        if line.strip().startswith("- ")
        and line[2:].strip().lower() != "none"
        and line[2:].strip().casefold() != fallback_sentence
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
        if stored_item is not None and str(stored_item).strip() != item:
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


def extract_evidence_status_entries(body: str) -> dict[str, object]:
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
        match = EVIDENCE_STATUS_LINE_RE.match(line)
        if not match:
            invalid_lines.append(line)
            continue
        item = match.group("item").strip()
        if item in entries:
            duplicate_items.append(item)
            continue
        entries[item] = {
            "status": match.group("status"),
            "detail": match.group("detail").strip(),
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

    parsed = _structured_evidence_entries(body, requested_evidence) or extract_evidence_status_entries(body)
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
        preview = ", ".join(parts)
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
    pending_ci_items = accounting.get("pending_ci_items", [])
    if pending_ci_items:
        preview = "; ".join(str(item) for item in pending_ci_items[:3])
        return (
            "requested evidence is pending CI and review must stay in request_changes; "
            f"pending-ci: {preview}"
        )
    return None


def _normalize_evidence_item(item: str) -> str:
    return item.strip().strip("`").strip()


def _evidence_item_kind(item: str) -> str:
    normalized = _normalize_evidence_item(item).casefold()
    if normalized.startswith("swift test"):
        return "test"
    if normalized.startswith("swift build"):
        return "build"
    if "screenshot" in normalized or "screen recording" in normalized:
        return "screenshot"
    return "other"


def _needs_macos_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) != "other" for item in requested_evidence)


def _needs_screenshot_evidence(requested_evidence: list[str]) -> bool:
    return any(_evidence_item_kind(item) == "screenshot" for item in requested_evidence)


def _extract_test_commands(requested_evidence: list[str]) -> list[str]:
    return [
        _normalize_evidence_item(item)
        for item in requested_evidence
        if _evidence_item_kind(item) == "test"
    ]


def _swift_test_filter_selector(command: str) -> str | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    if len(parts) < 4 or parts[:2] != ["swift", "test"]:
        return None
    for index, part in enumerate(parts[2:], start=2):
        if part == "--filter" and index + 1 < len(parts):
            return parts[index + 1]
        if part.startswith("--filter="):
            return part.split("=", 1)[1]
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
    swift_filter_commands = [
        command
        for command in commands
        if _swift_test_filter_selector(command) is not None
    ]
    if not swift_filter_commands:
        return []

    # Look up through the entrypoint module to allow mock.patch.object patching.
    _mod = sys.modules.get("run_contributor", sys.modules[__name__])
    listed_tests = _mod._listed_swift_tests(env)
    if not listed_tests:
        log(
            "skipping `swift test list` evidence selector preflight because no Swift Testing "
            "specifiers were returned; the project may need to build first"
        )
        return []

    errors: list[str] = []
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
) -> tuple[str, str]:
    kind = _evidence_item_kind(item)
    normalized = _normalize_evidence_item(item)
    uploaded_screenshot_urls = screenshot_urls or []

    if kind == "build":
        if build_succeeded:
            return "complete", "`swift build` succeeded on self-hosted macOS CI"
        return "blocked", "self-hosted macOS CI `swift build` failed; see workflow logs"
    if kind == "test":
        if tests_succeeded:
            if _test_output_has_no_matching_tests(normalized, test_output):
                return "blocked", f"self-hosted macOS CI `{normalized}` matched no tests; see test-output.txt"
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


def reconcile_pending_ci_evidence(
    body: str,
    *,
    build_succeeded: bool,
    tests_succeeded: bool,
    smoke_succeeded: bool,
    test_output: str = "",
    screenshot_upload_succeeded: bool = False,
    screenshot_urls: list[tuple[str, str]] | None = None,
) -> str:
    """Resolve pending-ci evidence lines after the macOS evidence job finishes."""
    metadata = _extract_evidence_metadata(body)
    if isinstance(metadata, dict) and isinstance(metadata.get("entries"), list):
        updated_entries: list[object] = []
        rendered_entries: list[dict[str, object]] = []
        for raw_entry in metadata["entries"]:
            if not isinstance(raw_entry, dict):
                updated_entries.append(raw_entry)
                continue
            entry = dict(raw_entry)
            if str(entry.get("status", "")).strip() == "pending-ci":
                status, detail = _pending_ci_resolution(
                    str(entry.get("item", "")).strip(),
                    build_succeeded=build_succeeded,
                    tests_succeeded=tests_succeeded,
                    smoke_succeeded=smoke_succeeded,
                    test_output=test_output,
                    screenshot_upload_succeeded=screenshot_upload_succeeded,
                    screenshot_urls=screenshot_urls,
                )
                entry["status"] = status
                entry["detail"] = detail
            updated_entries.append(entry)
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
                    f"- [{str(entry.get('status', '')).strip()}] {str(entry.get('item', '')).strip()} -- {str(entry.get('detail', '')).strip()}"
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

    lines = body.splitlines()
    updated: list[str] = []
    in_evidence_status = False

    for line in lines:
        if line.startswith("## "):
            in_evidence_status = line.strip() == "## Evidence Status"
            updated.append(line)
            continue
        if in_evidence_status:
            match = EVIDENCE_STATUS_LINE_RE.match(line)
            if match and match.group("status") == "pending-ci":
                item = match.group("item").strip()
                status, detail = _pending_ci_resolution(
                    item,
                    build_succeeded=build_succeeded,
                    tests_succeeded=tests_succeeded,
                    smoke_succeeded=smoke_succeeded,
                    test_output=test_output,
                    screenshot_upload_succeeded=screenshot_upload_succeeded,
                    screenshot_urls=screenshot_urls,
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
