#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Guard tests for Carl's Claude API call: transient errors retry with capped
backoff (the fleet shares one OAuth token, so 429s happen), the happy path is
untouched, and exhaustion fails cleanly. No network — urlopen and sleep mocked."""

from __future__ import annotations

import importlib.util
import io
import sys
import unittest
from pathlib import Path
from urllib.error import HTTPError

SCRIPT = Path(__file__).resolve().parents[1] / "carl-community.py"
spec = importlib.util.spec_from_file_location("carl_community", SCRIPT)
assert spec and spec.loader
carl = importlib.util.module_from_spec(spec)
sys.modules["carl_community"] = carl
spec.loader.exec_module(carl)


def _ok_response(text: str = "hi"):
    class R:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"content":[{"type":"text","text":"%s"}]}' % text.encode()

    return R()


def _http_error(code: int, headers: dict | None = None) -> HTTPError:
    return HTTPError("https://api", code, "err", headers or {}, io.BytesIO(b""))


class CallClaudeRetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self._orig_urlopen = carl.urlopen
        self._orig_sleep = carl.time.sleep
        carl.time.sleep = lambda _s: None  # instant

    def tearDown(self) -> None:
        carl.urlopen = self._orig_urlopen
        carl.time.sleep = self._orig_sleep

    def test_retries_transient_429_then_succeeds(self) -> None:
        calls = {"n": 0}

        def flaky(_req, timeout=60):
            calls["n"] += 1
            if calls["n"] < 3:
                raise _http_error(429)
            return _ok_response("hello")

        carl.urlopen = flaky
        out = carl.call_claude("s", "u", model="claude-sonnet-5", oauth_token="t")
        self.assertEqual(out, "hello")
        self.assertEqual(calls["n"], 3)

    def test_exhausts_cleanly_when_always_rate_limited(self) -> None:
        calls = {"n": 0}

        def always(_req, timeout=60):
            calls["n"] += 1
            raise _http_error(429)

        carl.urlopen = always
        with self.assertRaises(carl.CarlError):
            carl.call_claude("s", "u", model="m", oauth_token="t", max_attempts=3)
        self.assertEqual(calls["n"], 3)

    def test_non_retryable_status_fails_immediately(self) -> None:
        calls = {"n": 0}

        def unauthorized(_req, timeout=60):
            calls["n"] += 1
            raise _http_error(401)

        carl.urlopen = unauthorized
        with self.assertRaises(carl.CarlError):
            carl.call_claude("s", "u", model="m", oauth_token="t")
        self.assertEqual(calls["n"], 1)  # no retry on a non-transient error

    def test_happy_path_makes_one_call(self) -> None:
        calls = {"n": 0}

        def ok(_req, timeout=60):
            calls["n"] += 1
            return _ok_response("done")

        carl.urlopen = ok
        self.assertEqual(carl.call_claude("s", "u", model="m", oauth_token="t"), "done")
        self.assertEqual(calls["n"], 1)

    def test_retry_after_header_is_honored_and_capped(self) -> None:
        self.assertEqual(carl._retry_delay(_http_error(429, {"retry-after": "5"}), 1), 5.0)
        # A huge Retry-After is capped so a run fails cleanly, not hangs.
        capped = carl._retry_delay(_http_error(429, {"retry-after": "9999"}), 1)
        self.assertEqual(capped, carl.MAX_RETRY_DELAY_SECONDS)


if __name__ == "__main__":
    unittest.main()
