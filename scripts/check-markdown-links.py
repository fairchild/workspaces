#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check that relative links in Markdown files resolve to real files.

Archiving or renaming a file (e.g. `git mv backlog/foo.md backlog/done/foo.md`)
does not re-point anything that linked to it — this catches that class of
breakage before merge. Only real Markdown link syntax `[text](target)` /
`![alt](target)` is checked; fenced code blocks and inline code spans are
stripped first (both commonly hold illustrative, non-link paths), matched by
delimiter run length like CommonMark, not by naive backtick pairing.

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
}

# Root-scoped: excluded only when rooted at the repo top, not wherever the
# name happens to appear (docs/backlog/x.md is not backlog/**).
EXCLUDE_ROOT_PREFIXES = (
    "backlog/",  # fast-churn task ledger with its own archive lifecycle, not reference docs
    "docs/archive/",  # frozen historical snapshot, not maintained
)

FENCE_LINE_RE = re.compile(r"^\s*(`{3,}|~{3,})")
INLINE_CODE_RE = re.compile(r"(`+)(?:(?!\1).)*?\1")
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")

# Known non-path prose fillers ("[Web CI passed](url)", "cp X Y") found by
# manual audit — exact match only, after stripping any <...> wrapping.
KNOWN_PLACEHOLDERS = {"url", "link", "run url"}


def strip_fenced_code(text: str) -> str:
    """Blank fenced code-block lines, preserving line count and fence semantics:
    a closing fence must reuse the opening's character and be >= its length."""
    out_lines = []
    fence_char: str | None = None
    fence_len = 0
    for line in text.split("\n"):
        if fence_char is None:
            m = FENCE_LINE_RE.match(line)
            if m:
                fence_char = m.group(1)[0]
                fence_len = len(m.group(1))
                out_lines.append("")
                continue
            out_lines.append(line)
        else:
            stripped = line.strip()
            if stripped and set(stripped) == {fence_char} and len(stripped) >= fence_len:
                fence_char = None
                fence_len = 0
            out_lines.append("")
    return "\n".join(out_lines)


def strip_non_prose(text: str) -> str:
    text = strip_fenced_code(text)
    text = INLINE_CODE_RE.sub("", text)
    return text


def resolve_target(md_file: Path, repo_root: Path, path_part: str) -> Path | None:
    """Resolve a link's path component. Returns None for targets that should
    be reported as broken outright (absolute-path leaks, escapes repo root)."""
    if path_part.startswith("/"):
        # Markdown renderers (GitHub included) treat a leading "/" as
        # relative to the site/domain root, not the repo checkout — never a
        # valid same-repo relative link, and exactly the class of absolute
        # local-worktree-path leak this checker exists to catch.
        return None
    resolved = (md_file.parent / path_part).resolve()
    if not resolved.is_relative_to(repo_root):
        return None
    return resolved


def is_checkable_target(path_part: str) -> bool:
    return path_part not in KNOWN_PLACEHOLDERS


def is_excluded(path: Path, repo_root: Path) -> bool:
    if any(part in EXCLUDE_DIRS for part in path.parts):
        return True
    try:
        rel_posix = path.relative_to(repo_root).as_posix()
    except ValueError:
        return False
    return any(rel_posix.startswith(prefix) for prefix in EXCLUDE_ROOT_PREFIXES)


def iter_markdown_files(roots: list[Path], repo_root: Path) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
            continue
        files.extend(p for p in root.rglob("*.md") if not is_excluded(p, repo_root))
    return sorted(set(files))


def check_file(md_file: Path, repo_root: Path) -> list[tuple[int, str]]:
    problems = []
    raw = md_file.read_text(encoding="utf-8", errors="replace")
    prose = strip_non_prose(raw)
    for lineno, line in enumerate(prose.splitlines(), start=1):
        for m in LINK_RE.finditer(line):
            target = m.group(1).strip()
            if target.startswith(("http://", "https://", "mailto:", "tel:", "#")):
                continue
            path_part = target.split("#", 1)[0].strip().strip("<>").strip()
            if not path_part or not is_checkable_target(path_part):
                continue
            resolved = resolve_target(md_file, repo_root, path_part)
            if resolved is None or not resolved.exists():
                problems.append((lineno, target))
    return problems


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    roots = [Path(a).resolve() for a in argv] if argv else [repo_root]
    files = iter_markdown_files(roots, repo_root)

    total_problems = 0
    for md_file in files:
        for lineno, target in check_file(md_file, repo_root):
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
