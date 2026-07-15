#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for contributor output extraction robustness."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    REPO_ROOT
    / ".agents"
    / "skills"
    / "cofounder-contributor"
    / "scripts"
    / "validate-agent-output.py"
)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


validate_agent_output = load_module("validate_agent_output", SCRIPT_PATH)


class ValidateAgentOutputTests(unittest.TestCase):
    def test_extract_structured_skips_preamble_horizontal_rule(self) -> None:
        raw = """Working from the full diff first.

---

---
action: review_pr
persona: April Clearwater, Application Lead
pr_number: 571
verdict: approve_with_followups
---

**Verdict: Approve with follow-ups**

## Code Review
Looks safe.
"""

        data = validate_agent_output.extract_structured(raw)

        self.assertEqual(data["action"], "review_pr")
        self.assertEqual(data["pr_number"], 571)
        self.assertIn("Looks safe.", data["body"])

        validated = validate_agent_output.validate_data(data)
        self.assertEqual(validated["verdict"], "approve_with_followups")

    def test_extract_structured_accepts_frontmatter_inside_yaml_fence(self) -> None:
        raw = """Analysis before final output.

```yaml
---
action: review_pr
persona: April Clearwater, Application Lead
pr_number: 571
verdict: approve
---

**Verdict: Approve**
```
"""

        data = validate_agent_output.extract_structured(raw)

        self.assertEqual(data["action"], "review_pr")
        self.assertEqual(data["verdict"], "approve")

    def test_review_verdict_rejects_non_decisions(self) -> None:
        with self.assertRaisesRegex(validate_agent_output.ValidationError, "verdict"):
            validate_agent_output.validate_data(
                {
                    "action": "review_pr",
                    "persona": "April Clearwater, Application Lead",
                    "pr_number": 571,
                    "verdict": "comment",
                    "body": "Looks mostly fine.",
                }
            )


if __name__ == "__main__":
    unittest.main()
