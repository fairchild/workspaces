#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compatibility shim for the shared skill frontmatter parser."""

from __future__ import annotations

import runpy
from pathlib import Path


if __name__ == "__main__":
    runpy.run_path(
        str(
            Path(__file__).resolve().parents[1]
            / "skills"
            / "cofounder-contributor"
            / "scripts"
            / "parse-frontmatter.py"
        ),
        run_name="__main__",
    )
