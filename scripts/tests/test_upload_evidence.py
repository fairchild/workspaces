#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Evidence upload contract tests.

Intent: protect video MIME handling and the local upload-size guard without
network access, secrets, UI access, or live evidence-store mutations.
"""

from __future__ import annotations

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "upload-evidence.py"
SPEC = importlib.util.spec_from_file_location("upload_evidence", SCRIPT_PATH)
assert SPEC and SPEC.loader
upload_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upload_evidence)


class FakeResponse:
    status = 201

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None


class UploadEvidenceTests(unittest.TestCase):
    def run_main(self, file: Path) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = [
            str(SCRIPT_PATH),
            str(file),
            "--repo",
            "workspaces",
            "--pr",
            "1027",
            "--base-url",
            "https://evidence.example",
        ]
        with (
            patch.object(sys, "argv", argv),
            patch.dict(os.environ, {"EVIDENCE_UPLOAD_TOKEN": "test-token"}),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            result = upload_evidence.main()
        return result, stdout.getvalue(), stderr.getvalue()

    def test_webm_and_mp4_upload_with_browser_video_content_types(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for extension, expected in (
                ("webm", "video/webm"),
                ("mp4", "video/mp4"),
            ):
                with self.subTest(extension=extension):
                    video = Path(tmp) / f"hero-flow.{extension}"
                    video.write_bytes(b"video-evidence")
                    with patch.object(
                        upload_evidence, "urlopen", return_value=FakeResponse()
                    ) as urlopen:
                        result, stdout, stderr = self.run_main(video)

                    self.assertEqual(result, 0, stderr)
                    request = urlopen.call_args.args[0]
                    self.assertEqual(request.get_header("Content-type"), expected)
                    self.assertIn(f"hero-flow.{extension}", stdout)

    def test_rejects_files_over_the_upload_cap_before_reading_or_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            video = Path(tmp) / "too-large.webm"
            with video.open("wb") as handle:
                handle.truncate(upload_evidence.MAX_UPLOAD_BYTES + 1)

            with patch.object(upload_evidence, "urlopen") as urlopen:
                result, _stdout, stderr = self.run_main(video)

            self.assertEqual(result, 1)
            self.assertIn("exceeds the 50 MiB upload limit", stderr)
            urlopen.assert_not_called()

    def test_rechecks_the_bytes_when_a_recording_grows_after_stat(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            video = Path(tmp) / "still-recording.webm"
            video.write_bytes(b"123")

            with (
                patch.object(upload_evidence, "MAX_UPLOAD_BYTES", 4),
                patch.object(Path, "read_bytes", return_value=b"12345"),
                patch.object(upload_evidence, "urlopen") as urlopen,
            ):
                result, _stdout, stderr = self.run_main(video)

            self.assertEqual(result, 1)
            self.assertIn("file grew to 5 bytes", stderr)
            urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
