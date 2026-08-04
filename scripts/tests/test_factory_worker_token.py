#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "pyjwt[crypto]>=2.8",
#     "cryptography>=42",
# ]
# ///
"""Tests for scripts/factory-worker-token.py.

Covers JWT construction against a throwaway RSA key (never a real App key),
the readiness classifier `resolve()` with the network calls stubbed out, and
the HTTP-status-to-state mapping in find_installation_id/mint_installation_token
via a faked urlopen. No real GitHub App exists yet (issue #1180), so nothing
here exercises the live API — see docs/development/factory-current-state.md
for the manual end-to-end proof step once the App is created.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError, URLError

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "factory-worker-token.py"


def load_module():
    spec = importlib.util.spec_from_file_location("factory_worker_token", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["factory_worker_token"] = module
    spec.loader.exec_module(module)
    return module


worker_token = load_module()


def generate_test_keypair() -> tuple[bytes, bytes]:
    """A throwaway RSA keypair for exercising JWT construction. Not a real App key."""
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return private_pem, public_pem


class FakeHTTPResponse:
    def __init__(self, payload: dict):
        self._data = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False

    def read(self) -> bytes:
        return self._data


def http_error(code: int, body: bytes = b"{}") -> HTTPError:
    return HTTPError(url="https://api.github.com/x", code=code, msg="error", hdrs=None, fp=io.BytesIO(body))


class MintJwtTests(unittest.TestCase):
    def setUp(self):
        self.private_pem, self.public_pem = generate_test_keypair()

    def test_signs_with_rs256(self):
        token = worker_token.mint_jwt("123456", self.private_pem, now=1_800_000_000)
        self.assertEqual(jwt.get_unverified_header(token)["alg"], "RS256")

    def test_claims_carry_app_id_and_clock_drift_buffer(self):
        now = 1_800_000_000
        token = worker_token.mint_jwt("123456", self.private_pem, now=now)
        claims = jwt.decode(token, self.public_pem, algorithms=["RS256"], options={"verify_iat": False, "verify_exp": False})
        self.assertEqual(claims["iss"], "123456")
        self.assertEqual(claims["iat"], now - worker_token.JWT_CLOCK_DRIFT_SECONDS)

    def test_expiry_stays_under_githubs_ten_minute_cap(self):
        token = worker_token.mint_jwt("123456", self.private_pem, now=1_800_000_000)
        claims = jwt.decode(token, self.public_pem, algorithms=["RS256"], options={"verify_iat": False, "verify_exp": False})
        self.assertLess(claims["exp"] - claims["iat"], 600)
        self.assertGreater(claims["exp"], claims["iat"])

    def test_token_verifies_against_the_matching_public_key(self):
        token = worker_token.mint_jwt("123456", self.private_pem, now=int(time.time()))
        claims = jwt.decode(token, self.public_pem, algorithms=["RS256"])
        self.assertEqual(claims["iss"], "123456")

    def test_token_rejected_by_a_different_keypair(self):
        _, other_public_pem = generate_test_keypair()
        token = worker_token.mint_jwt("123456", self.private_pem, now=int(time.time()))
        with self.assertRaises(jwt.InvalidSignatureError):
            jwt.decode(token, other_public_pem, algorithms=["RS256"])

    def test_malformed_key_raises_not_configured(self):
        with self.assertRaises(worker_token.WorkerTokenError) as ctx:
            worker_token.mint_jwt("123456", b"not a real private key")
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.NOT_CONFIGURED)

    def test_encrypted_key_raises_not_configured(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        encrypted_pem = key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.BestAvailableEncryption(b"secret"),
        )
        with self.assertRaises(worker_token.WorkerTokenError) as ctx:
            worker_token.mint_jwt("123456", encrypted_pem)
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.NOT_CONFIGURED)

    def test_public_key_instead_of_private_raises_not_configured(self):
        with self.assertRaises(worker_token.WorkerTokenError) as ctx:
            worker_token.mint_jwt("123456", self.public_pem)
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.NOT_CONFIGURED)


class RepoResolutionTests(unittest.TestCase):
    def test_explicit_repo_flag_wins(self):
        self.assertEqual(worker_token.repo_from_env_or_git("owner/repo"), "owner/repo")

    @mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "fairchild/workspaces"}, clear=False)
    def test_falls_back_to_github_repository_env(self):
        self.assertEqual(worker_token.repo_from_env_or_git(None), "fairchild/workspaces")

    @mock.patch.dict(os.environ, {}, clear=True)
    def test_parses_ssh_remote_url(self):
        fake = mock.Mock(stdout="git@github.com:fairchild/workspaces.git\n")
        with mock.patch("subprocess.run", return_value=fake):
            self.assertEqual(worker_token.repo_from_env_or_git(None), "fairchild/workspaces")

    @mock.patch.dict(os.environ, {}, clear=True)
    def test_parses_https_remote_url(self):
        fake = mock.Mock(stdout="https://github.com/fairchild/workspaces.git\n")
        with mock.patch("subprocess.run", return_value=fake):
            self.assertEqual(worker_token.repo_from_env_or_git(None), "fairchild/workspaces")


class InstallationLookupTests(unittest.TestCase):
    def test_404_maps_to_app_not_installed(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(404)):
            with self.assertRaises(worker_token.WorkerTokenError) as ctx:
                worker_token.find_installation_id("jwt-token", "fairchild/workspaces")
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.APP_NOT_INSTALLED)

    def test_401_maps_to_not_configured(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(401)):
            with self.assertRaises(worker_token.WorkerTokenError) as ctx:
                worker_token.find_installation_id("jwt-token", "fairchild/workspaces")
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.NOT_CONFIGURED)

    def test_403_maps_to_not_configured(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(403)):
            with self.assertRaises(worker_token.WorkerTokenError) as ctx:
                worker_token.find_installation_id("jwt-token", "fairchild/workspaces")
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.NOT_CONFIGURED)

    def test_unexpected_status_propagates_as_http_error(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(500)):
            with self.assertRaises(HTTPError):
                worker_token.find_installation_id("jwt-token", "fairchild/workspaces")

    def test_success_returns_installation_id(self):
        with mock.patch.object(worker_token, "urlopen", return_value=FakeHTTPResponse({"id": 987654})):
            self.assertEqual(worker_token.find_installation_id("jwt-token", "fairchild/workspaces"), 987654)


class MintInstallationTokenTests(unittest.TestCase):
    def test_404_maps_to_app_not_installed(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(404, b'{"message": "not found"}')):
            with self.assertRaises(worker_token.WorkerTokenError) as ctx:
                worker_token.mint_installation_token("jwt-token", 987654, "fairchild/workspaces")
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.APP_NOT_INSTALLED)

    def test_401_maps_to_not_configured(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(401, b'{"message": "bad credentials"}')):
            with self.assertRaises(worker_token.WorkerTokenError) as ctx:
                worker_token.mint_installation_token("jwt-token", 987654, "fairchild/workspaces")
        self.assertEqual(ctx.exception.state, worker_token.WorkerTokenState.NOT_CONFIGURED)

    def test_unexpected_status_propagates_as_http_error(self):
        with mock.patch.object(worker_token, "urlopen", side_effect=http_error(500)):
            with self.assertRaises(HTTPError):
                worker_token.mint_installation_token("jwt-token", 987654, "fairchild/workspaces")

    def test_success_returns_token_payload(self):
        payload = {"token": "ghs_fake", "expires_at": "2026-08-04T21:00:00Z"}
        with mock.patch.object(worker_token, "urlopen", return_value=FakeHTTPResponse(payload)):
            self.assertEqual(worker_token.mint_installation_token("jwt-token", 987654, "fairchild/workspaces"), payload)

    def test_request_is_scoped_to_the_resolved_repository(self):
        captured: dict = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["body"] = json.loads(req.data.decode())
            return FakeHTTPResponse({"token": "ghs_fake", "expires_at": "2026-08-04T21:00:00Z"})

        with mock.patch.object(worker_token, "urlopen", side_effect=fake_urlopen):
            worker_token.mint_installation_token("jwt-token", 987654, "fairchild/workspaces")
        self.assertEqual(captured["url"], "https://api.github.com/app/installations/987654/access_tokens")
        self.assertEqual(captured["body"], {"repositories": ["workspaces"]})


class ResolveTests(unittest.TestCase):
    @mock.patch.dict(os.environ, {}, clear=True)
    def test_missing_both_env_vars_is_not_configured(self):
        result = worker_token.resolve("fairchild/workspaces")
        self.assertEqual(result.state, worker_token.WorkerTokenState.NOT_CONFIGURED)
        self.assertIn("FACTORY_WORKER_APP_ID", result.detail)
        self.assertIn("FACTORY_WORKER_APP_KEY", result.detail)

    @mock.patch.dict(os.environ, {"FACTORY_WORKER_APP_ID": "123456", "FACTORY_WORKER_APP_KEY": "/nonexistent/key.pem"}, clear=True)
    def test_missing_key_file_is_not_configured(self):
        result = worker_token.resolve("fairchild/workspaces")
        self.assertEqual(result.state, worker_token.WorkerTokenState.NOT_CONFIGURED)

    def test_app_not_installed_propagates_from_lookup(self):
        private_pem, _ = generate_test_keypair()
        with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as key_file:
            key_file.write(private_pem)
            key_path = key_file.name
        try:
            env = {"FACTORY_WORKER_APP_ID": "123456", "FACTORY_WORKER_APP_KEY": key_path}
            with mock.patch.dict(os.environ, env, clear=True):
                with mock.patch.object(worker_token, "find_installation_id", side_effect=worker_token.WorkerTokenError(worker_token.WorkerTokenState.APP_NOT_INSTALLED, "not installed")):
                    result = worker_token.resolve("fairchild/workspaces")
            self.assertEqual(result.state, worker_token.WorkerTokenState.APP_NOT_INSTALLED)
        finally:
            os.unlink(key_path)

    def test_working_state_carries_token_and_expiry(self):
        private_pem, _ = generate_test_keypair()
        with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as key_file:
            key_file.write(private_pem)
            key_path = key_file.name
        try:
            env = {"FACTORY_WORKER_APP_ID": "123456", "FACTORY_WORKER_APP_KEY": key_path}
            with mock.patch.dict(os.environ, env, clear=True):
                with mock.patch.object(worker_token, "find_installation_id", return_value=987654):
                    with mock.patch.object(worker_token, "mint_installation_token", return_value={"token": "ghs_fake", "expires_at": "2026-08-04T21:00:00Z"}):
                        result = worker_token.resolve("fairchild/workspaces")
            self.assertEqual(result.state, worker_token.WorkerTokenState.WORKING)
            self.assertEqual(result.token, "ghs_fake")
            self.assertEqual(result.expires_at, "2026-08-04T21:00:00Z")
            self.assertEqual(result.installation_id, 987654)
        finally:
            os.unlink(key_path)

    def test_check_mode_confirms_installation_without_minting_a_token(self):
        private_pem, _ = generate_test_keypair()
        with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as key_file:
            key_file.write(private_pem)
            key_path = key_file.name
        try:
            env = {"FACTORY_WORKER_APP_ID": "123456", "FACTORY_WORKER_APP_KEY": key_path}
            with mock.patch.dict(os.environ, env, clear=True):
                with mock.patch.object(worker_token, "find_installation_id", return_value=987654):
                    with mock.patch.object(worker_token, "mint_installation_token") as mint_mock:
                        result = worker_token.resolve("fairchild/workspaces", mint=False)
            mint_mock.assert_not_called()
            self.assertEqual(result.state, worker_token.WorkerTokenState.WORKING)
            self.assertIsNone(result.token)
            self.assertEqual(result.installation_id, 987654)
        finally:
            os.unlink(key_path)

    def test_network_error_propagates_to_caller(self):
        private_pem, _ = generate_test_keypair()
        with tempfile.NamedTemporaryFile(suffix=".pem", delete=False) as key_file:
            key_file.write(private_pem)
            key_path = key_file.name
        try:
            env = {"FACTORY_WORKER_APP_ID": "123456", "FACTORY_WORKER_APP_KEY": key_path}
            with mock.patch.dict(os.environ, env, clear=True):
                with mock.patch.object(worker_token, "find_installation_id", side_effect=URLError("no route to host")):
                    with self.assertRaises(URLError):
                        worker_token.resolve("fairchild/workspaces")
        finally:
            os.unlink(key_path)


if __name__ == "__main__":
    unittest.main()
