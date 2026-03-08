#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests for gh-discuss.py — unit tests (no network) + live verification.

Usage:
    test_gh_discuss.py              # run unit tests only
    test_gh_discuss.py --live       # also run live verification against GitHub
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

# Import the module under test by path
sys.path.insert(0, str(Path(__file__).parent))
import importlib
gh_discuss = importlib.import_module("gh-discuss")


# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

_results: list[tuple[str, bool, str]] = []


def test(name: str):
    """Decorator that captures test pass/fail."""
    def decorator(fn):
        def wrapper():
            try:
                fn()
                _results.append((name, True, ""))
            except Exception as e:
                _results.append((name, False, str(e)))
        return wrapper
    return decorator


def run_tests(tests: list, label: str) -> bool:
    for t in tests:
        t()
    passed = sum(1 for _, ok, _ in _results if ok)
    failed = sum(1 for _, ok, _ in _results if not ok)
    print(f"\n=== {label}: {passed} passed, {failed} failed ===\n")
    for name, ok, err in _results:
        status = "PASS" if ok else "FAIL"
        line = f"  {status}  {name}"
        if err:
            line += f"  ({err})"
        print(line)
    return failed == 0


# ---------------------------------------------------------------------------
# Unit tests — pure functions, no network, no credentials needed
# ---------------------------------------------------------------------------

@test("b64url: standard encoding")
def test_b64url_standard():
    result = gh_discuss._b64url(b'{"alg":"RS256","typ":"JWT"}')
    decoded = base64.urlsafe_b64decode(result + "==")
    assert decoded == b'{"alg":"RS256","typ":"JWT"}', f"roundtrip failed: {decoded}"


@test("b64url: no padding characters in output")
def test_b64url_no_padding():
    result = gh_discuss._b64url(b"test")
    assert "=" not in result, f"padding found: {result}"


@test("b64url: url-safe characters only")
def test_b64url_urlsafe():
    # bytes that would produce + and / in standard base64
    data = bytes(range(256))
    result = gh_discuss._b64url(data)
    assert "+" not in result, "contains +"
    assert "/" not in result, "contains /"


@test("generate_jwt: produces 3-part token")
def test_jwt_structure():
    # Generate a throwaway RSA key for testing
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        key_path = f.name
    try:
        subprocess.run(
            ["openssl", "genrsa", "-out", key_path, "2048"],
            capture_output=True, check=True,
        )
        jwt = gh_discuss._generate_jwt("12345", key_path)
        parts = jwt.split(".")
        assert len(parts) == 3, f"expected 3 parts, got {len(parts)}"
    finally:
        os.unlink(key_path)


@test("generate_jwt: header has RS256 alg")
def test_jwt_header():
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        key_path = f.name
    try:
        subprocess.run(
            ["openssl", "genrsa", "-out", key_path, "2048"],
            capture_output=True, check=True,
        )
        jwt = gh_discuss._generate_jwt("12345", key_path)
        header_b64 = jwt.split(".")[0]
        header = json.loads(base64.urlsafe_b64decode(header_b64 + "=="))
        assert header["alg"] == "RS256", f"alg={header['alg']}"
        assert header["typ"] == "JWT", f"typ={header['typ']}"
    finally:
        os.unlink(key_path)


@test("generate_jwt: iss is integer in payload")
def test_jwt_iss_integer():
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        key_path = f.name
    try:
        subprocess.run(
            ["openssl", "genrsa", "-out", key_path, "2048"],
            capture_output=True, check=True,
        )
        jwt = gh_discuss._generate_jwt("12345", key_path)
        payload_b64 = jwt.split(".")[1]
        payload = json.loads(base64.urlsafe_b64decode(payload_b64 + "=="))
        assert isinstance(payload["iss"], int), f"iss type={type(payload['iss'])}"
        assert payload["iss"] == 12345, f"iss={payload['iss']}"
    finally:
        os.unlink(key_path)


@test("generate_jwt: payload has iat and exp")
def test_jwt_timing():
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        key_path = f.name
    try:
        subprocess.run(
            ["openssl", "genrsa", "-out", key_path, "2048"],
            capture_output=True, check=True,
        )
        jwt = gh_discuss._generate_jwt("99999", key_path)
        payload_b64 = jwt.split(".")[1]
        payload = json.loads(base64.urlsafe_b64decode(payload_b64 + "=="))
        assert "iat" in payload, "missing iat"
        assert "exp" in payload, "missing exp"
        assert payload["exp"] > payload["iat"], "exp must be after iat"
        assert payload["exp"] - payload["iat"] <= 660, "token validity too long"
    finally:
        os.unlink(key_path)


@test("generate_jwt: signature is non-empty")
def test_jwt_signature():
    with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as f:
        key_path = f.name
    try:
        subprocess.run(
            ["openssl", "genrsa", "-out", key_path, "2048"],
            capture_output=True, check=True,
        )
        jwt = gh_discuss._generate_jwt("12345", key_path)
        sig = jwt.split(".")[2]
        assert len(sig) > 100, f"signature too short: {len(sig)}"
    finally:
        os.unlink(key_path)


@test("resolve_credentials: returns None when nothing configured")
def test_resolve_none():
    env_backup = {}
    for key in ["GH_DISCUSS_APP_ID", "GH_DISCUSS_INSTALLATION_ID", "GH_DISCUSS_PRIVATE_KEY_PATH"]:
        env_backup[key] = os.environ.pop(key, None)

    # Point config dir somewhere empty
    original = gh_discuss._resolve_app_credentials.__code__
    with tempfile.TemporaryDirectory() as tmpdir:
        # Monkey-patch Path.home temporarily
        real_home = Path.home
        Path.home = staticmethod(lambda: Path(tmpdir))
        try:
            result = gh_discuss._resolve_app_credentials()
            assert result is None, f"expected None, got {result}"
        finally:
            Path.home = real_home
            for key, val in env_backup.items():
                if val is not None:
                    os.environ[key] = val


@test("resolve_credentials: reads from config files")
def test_resolve_config_files():
    env_backup = {}
    for key in ["GH_DISCUSS_APP_ID", "GH_DISCUSS_INSTALLATION_ID", "GH_DISCUSS_PRIVATE_KEY_PATH"]:
        env_backup[key] = os.environ.pop(key, None)

    with tempfile.TemporaryDirectory() as tmpdir:
        config_dir = Path(tmpdir) / ".config" / "gh-discuss"
        config_dir.mkdir(parents=True)
        (config_dir / "app-id").write_text("111\n")
        (config_dir / "installation-id").write_text("222\n")
        pem = config_dir / "app.pem"
        pem.write_text("fake-key")

        real_home = Path.home
        Path.home = staticmethod(lambda: Path(tmpdir))
        try:
            result = gh_discuss._resolve_app_credentials()
            assert result is not None, "expected credentials"
            app_id, inst_id, key_path = result
            assert app_id == "111", f"app_id={app_id}"
            assert inst_id == "222", f"inst_id={inst_id}"
            assert key_path == str(pem), f"key_path={key_path}"
        finally:
            Path.home = real_home
            for key, val in env_backup.items():
                if val is not None:
                    os.environ[key] = val


@test("resolve_credentials: env vars override config files")
def test_resolve_env_override():
    with tempfile.TemporaryDirectory() as tmpdir:
        pem = Path(tmpdir) / "test.pem"
        pem.write_text("fake-key")

        env_backup = {}
        for key in ["GH_DISCUSS_APP_ID", "GH_DISCUSS_INSTALLATION_ID", "GH_DISCUSS_PRIVATE_KEY_PATH"]:
            env_backup[key] = os.environ.get(key)

        os.environ["GH_DISCUSS_APP_ID"] = "env-app"
        os.environ["GH_DISCUSS_INSTALLATION_ID"] = "env-inst"
        os.environ["GH_DISCUSS_PRIVATE_KEY_PATH"] = str(pem)

        try:
            result = gh_discuss._resolve_app_credentials()
            assert result is not None
            app_id, inst_id, key_path = result
            assert app_id == "env-app", f"app_id={app_id}"
            assert inst_id == "env-inst", f"inst_id={inst_id}"
        finally:
            for key, val in env_backup.items():
                if val is not None:
                    os.environ[key] = val
                else:
                    os.environ.pop(key, None)


@test("resolve_credentials: partial credentials return None")
def test_resolve_partial():
    env_backup = {}
    for key in ["GH_DISCUSS_APP_ID", "GH_DISCUSS_INSTALLATION_ID", "GH_DISCUSS_PRIVATE_KEY_PATH"]:
        env_backup[key] = os.environ.pop(key, None)

    with tempfile.TemporaryDirectory() as tmpdir:
        config_dir = Path(tmpdir) / ".config" / "gh-discuss"
        config_dir.mkdir(parents=True)
        (config_dir / "app-id").write_text("111\n")
        # Missing installation-id and app.pem

        real_home = Path.home
        Path.home = staticmethod(lambda: Path(tmpdir))
        try:
            result = gh_discuss._resolve_app_credentials()
            assert result is None, f"expected None with partial creds, got {result}"
        finally:
            Path.home = real_home
            for key, val in env_backup.items():
                if val is not None:
                    os.environ[key] = val


@test("comment_header: contains agent and branch")
def test_comment_header():
    header = gh_discuss.comment_header()
    assert "**Agent**:" in header, f"missing Agent: {header}"
    assert "**Branch**:" in header, f"missing Branch: {header}"


@test("get_category_id: case-insensitive lookup")
def test_category_lookup():
    info = {
        "categories": {"general": "cat-1", "q-a": "cat-2"},
        "category_names": {"General": "cat-1", "Q&A": "cat-2"},
    }
    assert gh_discuss.get_category_id(info, "General") == "cat-1"
    assert gh_discuss.get_category_id(info, "general") == "cat-1"
    assert gh_discuss.get_category_id(info, "Q&A") == "cat-2"


UNIT_TESTS = [
    test_b64url_standard,
    test_b64url_no_padding,
    test_b64url_urlsafe,
    test_jwt_structure,
    test_jwt_header,
    test_jwt_iss_integer,
    test_jwt_timing,
    test_jwt_signature,
    test_resolve_none,
    test_resolve_config_files,
    test_resolve_env_override,
    test_resolve_partial,
    test_comment_header,
    test_category_lookup,
]


# ---------------------------------------------------------------------------
# Live verification — requires credentials + network
# ---------------------------------------------------------------------------

def run_live_verification() -> bool:
    """Post a comment as the bot, verify the author, delete it."""
    print("\n=== Live Verification ===\n")

    # Step 1: Check credentials
    creds = gh_discuss._resolve_app_credentials()
    if creds is None:
        print("SKIP  no app credentials configured")
        return True

    print("1. Resolving app credentials...", end=" ")
    app_id, installation_id, key_path = creds
    print(f"ok (app_id={app_id})")

    # Step 2: Get installation token
    print("2. Getting installation token...", end=" ")
    token = gh_discuss._get_installation_token(app_id, installation_id, key_path)
    auth = {**os.environ, "GH_TOKEN": token}
    print(f"ok (token={token[:8]}...)")

    # Step 3: Get repo info
    print("3. Getting repo info...", end=" ")
    info = gh_discuss.repo_info(env=auth)
    print(f"ok ({info['slug']})")

    # Step 4: Find a discussion to comment on
    print("4. Finding a discussion...", end=" ")
    data = gh_discuss._graphql("""
    {
      repository(owner: "%s", name: "%s") {
        discussions(first: 1, states: OPEN) {
          nodes { id number title }
        }
      }
    }
    """ % (info["owner"], info["name"]), env=auth)

    discussions = data["data"]["repository"]["discussions"]["nodes"]
    if not discussions:
        print("SKIP  no open discussions to test with")
        return True

    disc = discussions[0]
    print(f"ok (#{disc['number']}: {disc['title'][:40]}...)")

    # Step 5: Post a test comment
    marker = f"__verify_{int(__import__('time').time())}__"
    print("5. Posting test comment as bot...", end=" ")
    comment_data = gh_discuss._graphql(
        """
        mutation($discId: ID!, $body: String!) {
          addDiscussionComment(input: {
            discussionId: $discId
            body: $body
          }) {
            comment { id }
          }
        }
        """,
        env=auth,
        discId=disc["id"],
        body=f"Verification test comment {marker}",
    )
    comment_id = comment_data["data"]["addDiscussionComment"]["comment"]["id"]
    print("ok")

    # Step 6: Read back and check author
    print("6. Verifying comment author...", end=" ")
    verify_data = gh_discuss._graphql("""
    {
      node(id: "%s") {
        ... on DiscussionComment {
          body
          author { login __typename }
        }
      }
    }
    """ % comment_id, env=auth)

    author_info = verify_data["data"]["node"]["author"]
    author = author_info["login"]
    author_type = author_info.get("__typename", "Unknown")
    is_bot = author_type == "Bot" or author != info["owner"]
    print(f"{'ok' if is_bot else 'FAIL'} (author: {author}, type: {author_type})")

    # Step 7: Delete the test comment
    print("7. Cleaning up test comment...", end=" ")
    gh_discuss._graphql(
        """
        mutation($id: ID!) {
          deleteDiscussionComment(input: { id: $id }) {
            comment { id }
          }
        }
        """,
        env=auth,
        id=comment_id,
    )
    print("ok")

    if is_bot:
        print(f"\nVERIFIED: Comments post as '{author}' (not '{info['owner']}')")
        return True
    else:
        print(f"\nFAIL: Comment posted as '{author}' — expected a bot account")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    live = "--live" in sys.argv

    ok = run_tests(UNIT_TESTS, "Unit Tests")

    if live:
        try:
            live_ok = run_live_verification()
            ok = ok and live_ok
        except SystemExit as e:
            print(f"\nLive verification aborted (exit code {e.code})")
            ok = False
        except Exception:
            traceback.print_exc()
            ok = False

    print()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
