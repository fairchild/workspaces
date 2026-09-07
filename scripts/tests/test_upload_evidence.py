#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Evidence upload contract tests.

Intent: protect video MIME handling, the local upload-size guard, and the rule
that the printed URL pairs the address we dialed with the key the store minted
— without network access, secrets, UI access, or live evidence-store
mutations.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from socket import gaierror
from unittest.mock import patch
from urllib.error import URLError
from urllib.parse import urlsplit


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "upload-evidence.py"
SPEC = importlib.util.spec_from_file_location("upload_evidence", SCRIPT_PATH)
assert SPEC and SPEC.loader
upload_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upload_evidence)


MINTED_SEGMENT = "PRF-zMRuZN3Ih0j14u_o3g"


class FakeResponse:
    status = 201

    def __init__(self, body: bytes = b"") -> None:
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None


def minting_store(request: object, *_args: object, **_kwargs: object) -> FakeResponse:
    """Stand in for the worker, transcribed from `src/index.ts` and `evidence.ts`.

    Both halves matter. The key comes from `url.pathname.slice(1)` through
    `mintKey`, which keeps a leading slash the caller sent rather than trimming
    it. The `url` field is built as `https://` plus `hostname`, hardcoding the
    scheme and dropping the port, so it is wrong for any store not reached over
    HTTPS on 443 — and a client that trusts it is caught here.
    """
    parts = urlsplit(request.full_url)  # type: ignore[attr-defined]
    path = parts.path[1:]
    cut = path.rfind("/")
    key = (
        f"{MINTED_SEGMENT}/{path}"
        if cut == -1
        else f"{path[:cut]}/{MINTED_SEGMENT}/{path[cut + 1:]}"
    )
    body = {"url": f"https://{parts.hostname}/{key}", "key": key}
    return FakeResponse(json.dumps(body).encode())


def minted_url(base_url: str, requested_url: str) -> str:
    """The one URL the object is readable at, given what we asked the store for."""
    head, _, filename = urlsplit(requested_url).path.rpartition("/")
    return f"{base_url.rstrip('/')}{head}/{MINTED_SEGMENT}/{filename}"


class UploadEvidenceTests(unittest.TestCase):
    def run_main(
        self, file: Path, base_url: str = "https://evidence.example"
    ) -> tuple[int, str, str]:
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
            base_url,
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
                        upload_evidence, "urlopen", side_effect=minting_store
                    ) as urlopen:
                        result, stdout, stderr = self.run_main(video)

                    self.assertEqual(result, 0, stderr)
                    request = urlopen.call_args.args[0]
                    self.assertEqual(request.get_header("Content-type"), expected)
                    self.assertEqual(request.get_header("Content-length"), "14")
                    self.assertIn(f"hero-flow.{extension}", stdout)

    def test_txt_upload_uses_utf8_plain_text_content_type(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "swift-test.txt"
            log.write_text("All tests passed\n", encoding="utf-8")
            with patch.object(
                upload_evidence, "urlopen", side_effect=minting_store
            ) as urlopen:
                result, stdout, stderr = self.run_main(log)

            self.assertEqual(result, 0, stderr)
            request = urlopen.call_args.args[0]
            self.assertEqual(
                request.get_header("Content-type"),
                "text/plain; charset=utf-8",
            )
            self.assertIn("swift-test.txt", stdout)

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

    def test_prints_the_minted_path_not_the_one_we_asked_for(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            shot = Path(tmp) / "sidebar.png"
            shot.write_bytes(b"png-bytes")

            with patch.object(
                upload_evidence, "urlopen", side_effect=minting_store
            ) as urlopen:
                result, stdout, stderr = self.run_main(shot)

            self.assertEqual(result, 0, stderr)
            requested = urlopen.call_args.args[0].full_url
            printed = stdout.strip()
            self.assertNotEqual(printed, requested)
            self.assertEqual(
                printed, minted_url("https://evidence.example", requested)
            )

    def test_keeps_the_scheme_and_port_of_a_local_worker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            shot = Path(tmp) / "sidebar.png"
            shot.write_bytes(b"png-bytes")

            with patch.object(
                upload_evidence, "urlopen", side_effect=minting_store
            ) as urlopen:
                result, stdout, stderr = self.run_main(
                    shot, base_url="http://127.0.0.1:8799"
                )

            self.assertEqual(result, 0, stderr)
            requested = urlopen.call_args.args[0].full_url
            self.assertEqual(
                stdout.strip(), minted_url("http://127.0.0.1:8799", requested)
            )

    def test_reaches_a_store_mounted_under_a_path_prefix(self) -> None:
        """The key already carries the prefix, so the join must not repeat it."""
        with tempfile.TemporaryDirectory() as tmp:
            shot = Path(tmp) / "sidebar.png"
            shot.write_bytes(b"png-bytes")

            with patch.object(
                upload_evidence, "urlopen", side_effect=minting_store
            ) as urlopen:
                result, stdout, stderr = self.run_main(
                    shot, base_url="http://127.0.0.1:8799/evidence"
                )

            self.assertEqual(result, 0, stderr)
            requested = urlopen.call_args.args[0].full_url
            printed = stdout.strip()
            self.assertEqual(printed, minted_url("http://127.0.0.1:8799", requested))
            self.assertEqual(printed.count("/evidence/"), 1, printed)

    def test_composed_url_carries_no_upload_credentials(self) -> None:
        """Reads are public, so whatever authorized the write stays out of it."""
        self.assertEqual(
            upload_evidence._public_url(
                "http://uploader:s3cret@127.0.0.1:8799/workspaces/shot.png",
                "workspaces/SEG/shot.png",
            ),
            "http://127.0.0.1:8799/workspaces/SEG/shot.png",
        )

    def test_reports_one_clear_line_when_the_store_cannot_be_dialed(self) -> None:
        """urllib hands the whole authority to the resolver, credentials included."""
        with tempfile.TemporaryDirectory() as tmp:
            shot = Path(tmp) / "sidebar.png"
            shot.write_bytes(b"png-bytes")

            with patch.object(
                upload_evidence,
                "urlopen",
                side_effect=URLError(gaierror(8, "nodename nor servname provided")),
            ):
                result, stdout, stderr = self.run_main(
                    shot, base_url="http://uploader:s3cret@127.0.0.1:8799"
                )

            self.assertEqual(result, 1)
            self.assertEqual(stdout, "")
            self.assertIn("could not reach", stderr)
            self.assertNotIn("s3cret", stderr)
            self.assertNotIn("Traceback", stderr)

    def test_fails_when_the_store_reports_no_usable_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            shot = Path(tmp) / "sidebar.png"
            shot.write_bytes(b"png-bytes")

            bodies = (
                b"",
                b"not json",
                b"{}",
                b'{"key": ""}',
                b'{"key": "   "}',
                b'{"key": "."}',
                b'{"key": "../escape.png"}',
                b'{"key": "workspaces/../../escape.png"}',
                b'{"key": "workspaces/sidebar.png\\nhttps://spoofed.example/x"}',
                b'{"url": "https://evidence.example/sidebar.png"}',
            )
            for body in bodies:
                with self.subTest(body=body):
                    with patch.object(
                        upload_evidence, "urlopen", return_value=FakeResponse(body)
                    ):
                        result, stdout, stderr = self.run_main(shot)

                    self.assertEqual(result, 1)
                    self.assertEqual(stdout, "")
                    self.assertIn("returned no usable key", stderr)


if __name__ == "__main__":
    unittest.main()
