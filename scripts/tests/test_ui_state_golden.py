#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Offline tests for scripts/ui-state-golden.sh (#1228).

Two properties the live lane depends on and cannot demonstrate itself:

* `update` is the golden's author, and writing an unchanged state rewrites the same
  bytes — so a golden refresh shows a real diff or none at all, never key-order churn.
  The shipped goldens under fixtures/ui-state/ are checked against that directly.
* `settle` is a per-golden declaration, validated where it is read, and skipped for a
  saved `--from-file` response (which cannot change no matter how long you wait).

Safe to run without network, secrets, UI access, or live GitHub mutations: every case
runs `--from-file` against a temp golden, so nothing is fetched and nothing under
fixtures/ is written.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "ui-state-golden.sh"
GOLDEN_DIR = REPO_ROOT / "fixtures" / "ui-state"

SHIPPED_GOLDENS = sorted(GOLDEN_DIR.glob("*.json"))


def wire_response(state: dict) -> dict:
    """The `/v1/ui-state` envelope shape the script consumes."""
    return {"ok": True, "result": {"state": state, "volatile": {"tabTitles": ["zsh"]}}}


class UIStateGoldenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="UIStateGoldenTests-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def write_json(self, name: str, payload: dict) -> Path:
        path = self.root / name
        path.write_text(json.dumps(payload, indent=2) + "\n")
        return path

    def run_script(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_PATH), *args], capture_output=True, text=True, cwd=self.root, env=env
        )

    def stub_live_app(self, states: list[dict]) -> dict[str, str]:
        """A fake operator credential plus a `curl` that serves `states` in order.

        Redirecting HOME moves the credential path the script reads, so the live fetch
        path — the only one a settle loop runs — is exercised without an app. The last
        state repeats once the list is exhausted.
        """
        home = self.root / "home"
        credential = home / "Library/Application Support/com.cloudcompute.workspaces"
        credential.mkdir(parents=True)
        (credential / "automation-operator.json").write_text(
            json.dumps({"socketPath": "/tmp/unused.sock", "handle": "operator"})
        )

        responses = self.root / "responses"
        responses.mkdir()
        for index, state in enumerate(states):
            (responses / f"{index}.json").write_text(json.dumps(wire_response(state)))

        stub_bin = self.root / "bin"
        stub_bin.mkdir()
        curl = stub_bin / "curl"
        curl.write_text(
            "#!/bin/sh\n"
            f'counter="{self.root}/curl.count"\n'
            'count=$(cat "$counter" 2>/dev/null || echo 0)\n'
            f'next=$((count + 1)); [ "$next" -ge {len(states)} ] && next={len(states) - 1}\n'
            'echo "$next" > "$counter"\n'
            f'cat "{responses}/$count.json" 2>/dev/null || cat "{responses}/{len(states) - 1}.json"\n'
        )
        curl.chmod(0o755)

        import os

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["PATH"] = f"{stub_bin}:{env['PATH']}"
        return env

    def test_shipped_goldens_are_already_in_update_output_form(self) -> None:
        """No churn: re-running update over an unchanged state rewrites the same bytes."""
        self.assertTrue(SHIPPED_GOLDENS, "expected goldens under fixtures/ui-state/")
        for golden in SHIPPED_GOLDENS:
            with self.subTest(golden=golden.name):
                original = golden.read_text()
                document = json.loads(original)
                copy = self.root / golden.name
                copy.write_text(original)
                wire = self.write_json("wire.json", wire_response(document["state"]))

                result = self.run_script(
                    "update", "--golden", str(copy), "--from-file", str(wire)
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(copy.read_text(), original)

    def test_update_carries_ignore_and_settle_forward(self) -> None:
        """Authored decisions survive a regeneration; observed state is replaced."""
        golden = self.write_json(
            "scoped.json",
            {
                "scenario": "scoped",
                "ignore": ["terminal.tabCount"],
                "settle": {"timeoutSeconds": 7, "pollSeconds": 2},
                "state": {"banners": []},
            },
        )
        wire = self.write_json("wire.json", wire_response({"banners": ["restore_sessions"]}))

        result = self.run_script("update", "--golden", str(golden), "--from-file", str(wire))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        written = json.loads(golden.read_text())
        self.assertEqual(written["ignore"], ["terminal.tabCount"])
        self.assertEqual(written["settle"], {"timeoutSeconds": 7, "pollSeconds": 2})
        self.assertEqual(written["state"], {"banners": ["restore_sessions"]})
        self.assertEqual(list(written), ["scenario", "ignore", "settle", "state"])

    def test_matching_state_verifies(self) -> None:
        golden = self.write_json(
            "match.json", {"scenario": "match", "ignore": [], "state": {"banners": []}}
        )
        wire = self.write_json("wire.json", wire_response({"banners": []}))

        result = self.run_script("verify", "--golden", str(golden), "--from-file", str(wire))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("✓ ui-state matches", result.stdout)

    def test_mismatch_fails_with_the_path(self) -> None:
        golden = self.write_json(
            "drift.json",
            {"scenario": "drift", "ignore": [], "state": {"banners": ["workspace_orphan_cleanup"]}},
        )
        wire = self.write_json("wire.json", wire_response({"banners": []}))

        result = self.run_script("verify", "--golden", str(golden), "--from-file", str(wire))

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("state.banners", result.stderr)

    def test_settle_waits_for_chrome_that_arrives_late(self) -> None:
        """The orphan-banner race: the banner is absent on the first read and present later."""
        golden = self.write_json(
            "late.json",
            {
                "scenario": "late",
                "ignore": [],
                "settle": {"timeoutSeconds": 10, "pollSeconds": 1},
                "state": {"banners": ["workspace_orphan_cleanup"]},
            },
        )
        env = self.stub_live_app([{"banners": []}, {"banners": ["workspace_orphan_cleanup"]}])

        result = self.run_script("verify", "--golden", str(golden), env=env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("✓ ui-state matches", result.stdout)
        self.assertIn("settled after", result.stderr)

    def test_settle_times_out_with_the_bound_and_the_final_mismatch(self) -> None:
        """State that never arrives fails on a deterministic bound, not by hanging."""
        golden = self.write_json(
            "never.json",
            {
                "scenario": "never",
                "ignore": [],
                "settle": {"timeoutSeconds": 2, "pollSeconds": 1},
                "state": {"banners": ["workspace_orphan_cleanup"]},
            },
        )
        env = self.stub_live_app([{"banners": []}])

        result = self.run_script("verify", "--golden", str(golden), env=env)

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("never settled", result.stderr)
        self.assertIn("within 2s", result.stderr)
        self.assertIn("state.banners", result.stderr)

    def test_settle_is_skipped_for_a_saved_response(self) -> None:
        """A file cannot change; waiting on one would only turn a failure into a slow failure."""
        golden = self.write_json(
            "waits.json",
            {
                "scenario": "waits",
                "ignore": [],
                "settle": {"timeoutSeconds": 30, "pollSeconds": 5},
                "state": {"banners": ["workspace_orphan_cleanup"]},
            },
        )
        wire = self.write_json("wire.json", wire_response({"banners": []}))

        result = self.run_script("verify", "--golden", str(golden), "--from-file", str(wire))

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("does not apply", result.stderr)
        self.assertNotIn("never settled", result.stderr)

    def test_settle_reports_its_bound(self) -> None:
        golden = self.write_json(
            "bounded.json",
            {
                "scenario": "bounded",
                "ignore": [],
                "settle": {"timeoutSeconds": 12, "pollSeconds": 3},
                "state": {},
            },
        )

        result = self.run_script("settle", "--golden", str(golden))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.split(), ["12", "3"])

    def test_no_settle_declaration_reports_zero(self) -> None:
        golden = self.write_json("plain.json", {"scenario": "plain", "ignore": [], "state": {}})

        result = self.run_script("settle", "--golden", str(golden))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.split(), ["0", "0"])

    def test_verify_refuses_a_malformed_settle_rather_than_ignoring_it(self) -> None:
        """The failure mode that would matter: verifying with the wait silently disabled."""
        golden = self.write_json(
            "bad-verify.json",
            {
                "scenario": "bad-verify",
                "ignore": [],
                "settle": {"timeoutSeconds": "soon"},
                "state": {"banners": []},
            },
        )
        wire = self.write_json("wire.json", wire_response({"banners": []}))

        result = self.run_script("verify", "--golden", str(golden), "--from-file", str(wire))

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("✓ ui-state matches", result.stdout)
        self.assertIn("timeoutSeconds", result.stderr)

    def test_malformed_settle_fails_loudly(self) -> None:
        """A typo must not silently disable the wait it was meant to declare."""
        for settle in ({"timeoutSeconds": "20"}, {"timeoutSeconds": 0}, {"pollSeconds": 1}, []):
            with self.subTest(settle=settle):
                golden = self.write_json(
                    "bad.json", {"scenario": "bad", "ignore": [], "settle": settle, "state": {}}
                )

                result = self.run_script("settle", "--golden", str(golden))

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("settle", result.stderr)


if __name__ == "__main__":
    unittest.main()
