#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Shared local docs catalog and search helpers."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


SEARCH_STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "can",
    "do",
    "does",
    "for",
    "how",
    "i",
    "in",
    "is",
    "it",
    "me",
    "of",
    "on",
    "or",
    "our",
    "should",
    "the",
    "to",
    "what",
    "where",
    "why",
    "with",
}


def title_case(value: str) -> str:
    return " ".join(part.capitalize() for part in re.split(r"[-_/]+", value) if part)


def title_from_markdown(content: str, fallback: str) -> str:
    match = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
    return match.group(1).replace("`", "").strip() if match else fallback


def summary_from_markdown(content: str) -> str:
    content = re.sub(r"^Last updated:\s*`?[^`\n]+`?\s*", "", content, flags=re.I | re.M)
    for raw_line in re.split(r"\n+", content):
        line = raw_line.strip()
        if not line or line.startswith(("#", "```", "|", "![", "[")):
            continue
        if re.match(r"^[-*\d.]+\s", line):
            continue
        return line.replace("**", "").replace("`", "")[:180]
    return ""


def local_group(source: str) -> str:
    parts = source.split("/")
    if len(parts) < 3:
        return "Reference"
    if parts[1] == "ops":
        return "Operations"
    return title_case(parts[1])


def local_type(source: str) -> str:
    if "/performance/" in source:
        return "Evidence"
    if "/ops/" in source or "runbook" in source or "runner" in source:
        return "Operations"
    if "/design/" in source or "/specs/" in source or "/plans/" in source:
        return "Design"
    if "/development/" in source or "/agents/" in source:
        return "Development"
    return "Reference"


def topic_appears(content: str, alias: str) -> bool:
    pattern = rf"(^|[^a-z0-9]){re.escape(alias)}([^a-z0-9]|$)"
    return re.search(pattern, content, re.I) is not None


def local_topics(content: str, source: str, catalog: list[dict[str, Any]]) -> list[str]:
    topics = [
        str(topic["id"])
        for topic in catalog
        if any(topic_appears(content, str(alias)) for alias in topic.get("aliases", []))
    ]
    for topic in ["lume", "ghostty", "performance", "evidence"]:
        if topic in source and topic not in topics:
            topics.append(topic)
    return list(dict.fromkeys(topics))


def rendered_route(markdown_path: str) -> str:
    return markdown_path.removesuffix(".md")


def rendered_href(markdown_path: str) -> str:
    return f"/docs/{rendered_route(markdown_path)}"


def source_for_entry(entry: dict[str, Any]) -> str:
    source = str(entry.get("source", ""))
    if source == "/README.md":
        return "README.md"
    if source == "/CONTEXT.md":
        return "CONTEXT.md"
    return source.lstrip("/")


def normalize_manifest_entry(entry: dict[str, Any]) -> dict[str, Any]:
    group = entry.get("group") or "Docs"
    return {
        "source": entry["source"],
        "dest": entry["dest"],
        "title": entry["title"],
        "group": group,
        "topics": entry.get("topics", []),
        "summary": entry.get("summary", ""),
        "type": entry.get("type", group),
        "published": entry.get("published", True),
    }


def load_sync_manifest(repo_root: Path) -> dict[str, Any]:
    manifest_path = repo_root / "web/scripts/docs-sync-manifest.json"
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def local_docs_manifest(repo_root: Path) -> dict[str, Any]:
    manifest = load_sync_manifest(repo_root)
    topic_catalog = manifest.get("topics", [])
    entries_by_dest = {
        entry["dest"]: normalize_manifest_entry(entry)
        for entry in manifest.get("documents", [])
    }
    public_sources = {
        str(entry.get("source", "")).lstrip("/")
        for entry in manifest.get("documents", [])
    }

    for source_path in sorted((repo_root / "docs").rglob("*.md")):
        source = source_path.relative_to(repo_root).as_posix()
        if source in public_sources:
            continue
        dest = source_path.relative_to(repo_root / "docs").as_posix()
        if dest in entries_by_dest:
            continue
        content = source_path.read_text(encoding="utf-8")
        entries_by_dest[dest] = {
            "source": source,
            "dest": dest,
            "title": title_from_markdown(content, title_case(Path(dest).stem)),
            "group": local_group(source),
            "topics": local_topics(content, source, topic_catalog),
            "summary": summary_from_markdown(content),
            "type": local_type(source),
            "published": False,
        }

    entries = sorted(entries_by_dest.values(), key=lambda entry: entry["dest"])
    return {
        "generatedBy": "scripts/docs_catalog.py",
        "local": True,
        "documents": [entry["dest"] for entry in entries],
        "renderedRoutes": [rendered_route(entry["dest"]) for entry in entries],
        "entries": entries,
        "topics": topic_catalog,
    }


def search_tokens(value: str) -> list[str]:
    return [
        token
        for token in re.findall(r"[a-z0-9][a-z0-9_-]*", value.lower())
        if len(token) > 1 and token not in SEARCH_STOPWORDS
    ]


def search_text_for_entry(entry: dict[str, Any], topic_labels: dict[str, str]) -> str:
    topics = [str(topic) for topic in entry.get("topics", [])]
    return " ".join(
        [
            str(entry.get("title", "")),
            str(entry.get("summary", "")),
            str(entry.get("dest", "")),
            str(entry.get("source", "")),
            str(entry.get("group", "")),
            str(entry.get("type", "")),
            " ".join(topics),
            " ".join(topic_labels.get(topic, topic) for topic in topics),
        ]
    ).lower()


def is_subsequence(needle: str, haystack: str) -> bool:
    index = 0
    for char in haystack:
        if index < len(needle) and needle[index] == char:
            index += 1
    return index == len(needle)


def token_match_score(token: str, words: list[str], haystack: str) -> int:
    if token in haystack:
        return 12
    best = 0
    for word in words:
        if word.startswith(token):
            best = max(best, 10)
        elif token.startswith(word) and len(word) >= 3:
            best = max(best, 8)
        elif len(token) >= 4 and is_subsequence(token, word):
            best = max(best, 5)
    return best


def fuzzy_doc_score(
    query: str, entry: dict[str, Any], topic_labels: dict[str, str]
) -> int:
    tokens = search_tokens(query)
    if not tokens:
        return 1
    haystack = search_text_for_entry(entry, topic_labels)
    words = search_tokens(haystack)
    score = 0
    matched = 0
    for token in tokens:
        match_score = token_match_score(token, words, haystack)
        if match_score:
            matched += 1
            score += match_score
    if matched < max(1, round(len(tokens) * 0.34)):
        return 0
    title = str(entry.get("title", "")).lower()
    dest = str(entry.get("dest", "")).lower()
    if any(token in title for token in tokens):
        score += 8
    if any(token in dest for token in tokens):
        score += 4
    return score


def safe_doc_excerpt(repo_root: Path, source: str, query: str) -> str:
    source_path = repo_root / source
    try:
        resolved = source_path.resolve()
        resolved.relative_to(repo_root.resolve())
    except (OSError, ValueError):
        return ""
    if not resolved.is_file():
        return ""
    try:
        content = resolved.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return ""

    query_terms = [
        term.lower() for term in re.findall(r"[a-z0-9][a-z0-9_-]+", query)
    ]
    blocks = [block.strip() for block in re.split(r"\n\s*\n", content) if block.strip()]
    if query_terms:
        heading_match = ""
        for block in blocks:
            lower = block.lower()
            if any(term in lower for term in query_terms):
                if block.startswith("#") and not heading_match:
                    heading_match = block
                    continue
                return re.sub(r"\s+", " ", block)[:700]
        if heading_match:
            return re.sub(r"\s+", " ", heading_match)[:700]
    return summary_from_markdown(content) or re.sub(r"\s+", " ", content.strip())[:700]


def search_result(entry: dict[str, Any], repo_root: Path, query: str) -> dict[str, Any]:
    dest = str(entry.get("dest", ""))
    source = source_for_entry(entry)
    return {
        "title": str(entry.get("title") or dest),
        "url": rendered_href(dest),
        "source": source,
        "dest": dest,
        "snippet": safe_doc_excerpt(repo_root, source, query)
        or str(entry.get("summary") or ""),
        "summary": str(entry.get("summary") or ""),
        "topics": entry.get("topics") or [],
        "group": entry.get("group") or "Reference",
        "type": entry.get("type") or entry.get("group") or "Reference",
    }


def search_docs(
    manifest: dict[str, Any],
    repo_root: Path,
    *,
    query: str = "",
    group: str = "",
    topic: str = "",
    doc_type: str = "",
    limit: int = 12,
) -> dict[str, Any]:
    topic_labels = {
        str(topic_entry.get("id")): str(topic_entry.get("label"))
        for topic_entry in manifest.get("topics", [])
    }
    filtered = []
    for index, entry in enumerate(manifest.get("entries", [])):
        if group and entry.get("group") != group:
            continue
        if topic and topic not in (entry.get("topics") or []):
            continue
        if doc_type and entry.get("type") != doc_type:
            continue
        score = fuzzy_doc_score(query, entry, topic_labels)
        if query and score <= 0:
            continue
        filtered.append((score, index, entry))

    filtered.sort(key=lambda item: (-item[0], item[1]) if query else item[1])
    limited = filtered[: max(0, limit)]
    return {
        "query": query,
        "total": len(filtered),
        "results": [
            search_result(entry, repo_root, query) for _, _, entry in limited
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["local-manifest", "search"],
        help="Catalog operation to run.",
    )
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--q", default="")
    parser.add_argument("--group", default="")
    parser.add_argument("--topic", default="")
    parser.add_argument("--type", default="")
    parser.add_argument("--limit", type=int, default=12)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    manifest = local_docs_manifest(repo_root)
    if args.command == "local-manifest":
        payload = manifest
    else:
        payload = search_docs(
            manifest,
            repo_root,
            query=args.q,
            group=args.group,
            topic=args.topic,
            doc_type=args.type,
            limit=args.limit,
        )
    print(json.dumps(payload, indent="\t"))


if __name__ == "__main__":
    main()
