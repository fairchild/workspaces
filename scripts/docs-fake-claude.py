#!/usr/bin/env python3
"""Deterministic Claude Code fixture for local docs tests."""

from __future__ import annotations

import json
import sys


def prompt_text() -> str:
    try:
        return sys.argv[sys.argv.index("-p") + 1]
    except (ValueError, IndexError):
        return " ".join(sys.argv)


def query_from_prompt(prompt: str) -> str:
    try:
        payload = json.loads(prompt)
    except json.JSONDecodeError:
        return prompt
    return str(payload.get("query") or prompt)


def answer_for_query(query: str) -> dict:
    lower = query.lower()
    if "lume" in lower or "lum" in lower or "daemon" in lower or "fail" in lower:
        answer = (
            "Lume daemon reliability lives in the Lume integration and validation docs. "
            "Use the local rendered docs first, then raw `.md` paths when source text is needed."
        )
        return {
            "answer": answer,
            "source": "docs/development/lume-integration.md",
            "title": "Lume Integration",
            "url": "/docs/development/lume-integration",
        }
    if "ghostty" in lower or "shortcut" in lower:
        answer = (
            "Ghostty shortcut and split behavior is documented around libghostty "
            "integration, shortcut routing, and terminal session behavior."
        )
        return {
            "answer": answer,
            "source": "docs/development/libghostty-integration.md",
            "title": "libghostty Integration",
            "url": "/docs/development/libghostty-integration",
        }
    if "merge" in lower or "evidence" in lower:
        answer = (
            "A mergeable PR needs evidence, reviewable validation, and links that prove "
            "the behavior changed safely."
        )
        return {
            "answer": answer,
            "source": "docs/development/mergeability-standard.md",
            "title": "Mergeability Standard",
            "url": "/docs/development/mergeability-standard",
        }

    answer = (
        "The docs server renders extensionless paths for the nice reader and keeps raw "
        "Markdown at `.md` URLs. Public docs are curated; the local operator index is "
        "exhaustive and local-only."
    )
    return {
        "answer": answer,
        "source": "docs/README.md",
        "title": "WorkSpaces Docs Site",
        "url": "/docs/docs-site",
    }


def main() -> None:
    result = answer_for_query(query_from_prompt(prompt_text()))
    answer = result["answer"]
    print(
        json.dumps(
            {
                "type": "result",
                "session_id": "docs-fake-claude",
                "total_cost_usd": 0,
                "result": json.dumps(
                    {
                        "answer_markdown": answer,
                        "copy_text": answer,
                        "citations": [
                            {
                                "title": result["title"],
                                "url": result["url"],
                                "source": result["source"],
                                "snippet": answer,
                            }
                        ],
                    }
                ),
            }
        )
    )


if __name__ == "__main__":
    main()
