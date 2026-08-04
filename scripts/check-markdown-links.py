#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check that relative links in Markdown files resolve to real files.

Archiving or renaming a file (e.g. `git mv backlog/foo.md backlog/done/foo.md`)
does not re-point anything that linked to it — this catches that class of
breakage before merge. Only real Markdown link syntax `[text](target)` /
`![alt](target)` is checked; backtick code spans and fenced code blocks are
stripped first, since those commonly hold illustrative (non-link) paths.

Usage: check-markdown-links.py [PATH ...]  (defaults to repo root)
Exit 0 if every link resolves, 1 with a per-line report otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

EXCLUDE_DIRS = {
    ".git",
    "node_modules",
    ".build",
    "DerivedData",
    ".swiftpm",
    ".venv",
    "dist",
    ".next",
    "backlog",  # fast-churn task ledger with its own archive lifecycle, not reference docs
    "docs/archive",  # frozen historical snapshot, not maintained
}

FENCE_RE = re.compile(r"```.*?```|~~~.*?~~~", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]+`")
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")


def strip_non_prose(text: str) -> str:
    text = FENCE_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    text = INLINE_CODE_RE.sub("", text)
    return text


def is_checkable_target(target: str) -> bool:
    if target.startswith(("http://", "https://", "mailto:", "tel:", "#")):
        return False
    # Placeholder-y example targets ("url", "link", "<run url>") carry no
    # path shape (no '.' and no '/') and aren't meant to resolve.
    path_part = target.split("#", 1)[0].strip().strip("<>")
    return "." in path_part or "/" in path_part


def is_excluded(path: Path) -> bool:
    posix = f"/{path.as_posix()}/"
    return any(f"/{excl}/" in posix for excl in EXCLUDE_DIRS)


def iter_markdown_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
            continue
        files.extend(p for p in root.rglob("*.md") if not is_excluded(p))
    return sorted(set(files))


def check_file(md_file: Path, repo_root: Path) -> list[tuple[int, str, str]]:
    problems = []
    raw = md_file.read_text(encoding="utf-8", errors="replace")
    prose = strip_non_prose(raw)
    for lineno, line in enumerate(prose.splitlines(), start=1):
        for m in LINK_RE.finditer(line):
            target = m.group(1).strip()
            if not is_checkable_target(target):
                continue
            path_part = target.split("#", 1)[0].strip()
            if not path_part:
                continue
            if path_part.startswith("/"):
                resolved = (repo_root / path_part.lstrip("/")).resolve()
            else:
                resolved = (md_file.parent / path_part).resolve()
            if not resolved.exists():
                problems.append((lineno, target, str(resolved)))
    return problems


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    roots = [Path(a).resolve() for a in argv] if argv else [repo_root]
    files = iter_markdown_files(roots)

    total_problems = 0
    for md_file in files:
        for lineno, target, resolved in check_file(md_file, repo_root):
            rel = md_file.relative_to(repo_root) if md_file.is_relative_to(repo_root) else md_file
            print(f"{rel}:{lineno}: broken link -> {target}")
            total_problems += 1

    if total_problems:
        print(f"\n{total_problems} broken link(s) in {len(files)} file(s) checked.")
        return 1

    print(f"OK: {len(files)} Markdown file(s) checked, no broken relative links.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
