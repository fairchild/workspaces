#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""CI tripwire: every `ProcessRunner.run` call in Sources/ passes `timeout:`.

An un-timed subprocess call hangs its caller when the child never exits (network
mount, stale index.lock — see #640 and #1234). Call sites that are un-timed by
design (Lume/SSH/Daytona, where callers own outer deadlines) live in ALLOWLIST;
everything else must pass an explicit `timeout:` argument. Comments and string
literals are stripped before matching, so mentions in doc comments don't count
and a `timeout:` hidden inside a string doesn't satisfy the check.

Usage: check-subprocess-timeouts.py [--root REPO_ROOT]
Exit 0 when every call site is timed or allowlisted, 1 with a per-line report
otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CALL_PATTERN = re.compile(r"ProcessRunner\s*\.\s*run\s*\(")
TIMEOUT_LABEL = re.compile(r"(?<![A-Za-z0-9_])timeout\s*:")

# Files whose ProcessRunner.run calls may omit `timeout:`. Paths are relative to
# the repo root. Entries that no longer exist are ignored; a renamed file drops
# out of the allowlist and its un-timed calls become violations, which is the
# desired failure mode.
ALLOWLIST = {
    "Sources/WorkspaceManagerCore/Services/ProcessRunner.swift",
    "Sources/WorkspaceManagerCore/Services/SSHBackend.swift",
    "Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift",
    "Sources/WorkspaceManagerCore/Services/LumeHTTPClient.swift",
    "Sources/WorkspaceManagerCore/Services/LumeRuntimeService.swift",
    "Sources/WorkspaceManagerCore/Services/LumeCLIRunner.swift",
    "Sources/WorkspaceManagerCore/Services/LumeBridgedVMReachability.swift",
}


def blank_comments_and_strings(text: str) -> str:
    """Replace comment and string-literal content with spaces, preserving
    newlines and offsets so line numbers computed on the result stay valid.
    String interpolation is blanked along with its string (a call site inside
    `\\(...)` is not recognized; none exist and none should)."""
    out = list(text)
    i = 0
    n = len(text)

    def blank(start: int, end: int) -> None:
        for j in range(start, end):
            if out[j] != "\n":
                out[j] = " "

    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            end = text.find("\n", i)
            end = n if end == -1 else end
            blank(i, end)
            i = end
        elif ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            j = i + 2
            while j < n and depth > 0:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif ch == "#" or ch == '"':
            hashes = 0
            j = i
            while j < n and text[j] == "#":
                hashes += 1
                j += 1
            if j >= n or text[j] != '"':
                i += 1
                continue
            if text.startswith('"""', j):
                opener_end = j + 3
                closer = '"""' + "#" * hashes
            else:
                opener_end = j + 1
                closer = '"' + "#" * hashes
            k = opener_end
            while k < n:
                if hashes == 0 and text[k] == "\\":
                    k += 2
                    continue
                if text.startswith(closer, k):
                    k += len(closer)
                    break
                k += 1
            else:
                k = n
            blank(i, k)
            i = k
        else:
            i += 1
    return "".join(out)


def has_top_level_timeout(code: str, open_paren: int) -> bool:
    """Whether the argument list starting at `open_paren` carries a `timeout:`
    label at depth 1 (labels inside nested calls or literals don't count)."""
    depth = 0
    top_level_chars: list[str] = []
    i = open_paren
    n = len(code)
    while i < n:
        ch = code[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                break
        elif depth == 1:
            top_level_chars.append(ch)
        i += 1
    return bool(TIMEOUT_LABEL.search("".join(top_level_chars)))


def scan_file(path: Path, root: Path) -> list[tuple[str, int]]:
    code = blank_comments_and_strings(path.read_text(encoding="utf-8"))
    violations: list[tuple[str, int]] = []
    for match in CALL_PATTERN.finditer(code):
        open_paren = match.end() - 1
        if not has_top_level_timeout(code, open_paren):
            line = code.count("\n", 0, match.start()) + 1
            violations.append((path.relative_to(root).as_posix(), line))
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repo root containing Sources/ (default: this script's repo)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    sources = root / "Sources"
    if not sources.is_dir():
        print(f"error: no Sources/ directory under {root}", file=sys.stderr)
        return 2

    violations: list[tuple[str, int]] = []
    checked = 0
    for path in sorted(sources.rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        if relative in ALLOWLIST:
            continue
        found = scan_file(path, root)
        checked += 1
        violations.extend(found)

    if violations:
        for relative, line in violations:
            print(f"{relative}:{line}: ProcessRunner.run without `timeout:`")
        print(
            "\nEvery subprocess call needs a deadline (a hung child hangs its"
            " caller — #640/#1234). Pass `timeout:` or, for calls whose outer"
            " deadline lives with the caller, add the file to ALLOWLIST in"
            " scripts/check-subprocess-timeouts.py with a justifying comment"
            " at the call site.",
            file=sys.stderr,
        )
        return 1

    print(f"OK: no un-timed ProcessRunner.run calls in {checked} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
