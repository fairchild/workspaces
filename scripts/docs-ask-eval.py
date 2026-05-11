#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run focused evals against the local WorkSpaces docs ask endpoint."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CASES = [
    {
        "id": "docs-navigation-contract",
        "query": "How do rendered docs URLs and raw markdown URLs work?",
        "must_mention": ["extensionless", ".md"],
        "expected_sources": ["docs/README.md"],
    },
    {
        "id": "lume-daemon",
        "query": "Where should I look for Lume daemon reliability and validation?",
        "must_mention": ["Lume", "daemon"],
        "expected_sources": ["docs/development/lume-integration.md"],
    },
    {
        "id": "ghostty-shortcuts",
        "query": "What docs explain Ghostty shortcut routing and split behavior?",
        "must_mention": ["Ghostty", "shortcut"],
        "expected_sources": ["docs/development/libghostty-integration.md"],
    },
    {
        "id": "merge-evidence",
        "query": "What proof should a PR include before it is considered mergeable?",
        "must_mention": ["evidence", "merge"],
        "expected_sources": ["docs/development/mergeability-standard.md"],
    },
    {
        "id": "operator-index",
        "query": "What is the local operator index for and how is it different from public docs?",
        "must_mention": ["local", "public"],
        "expected_sources": ["docs/README.md"],
    },
]


class EvalFailure(RuntimeError):
    pass


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request(
    base_url: str,
    path: str,
    *,
    method: str = "GET",
    body: dict | None = None,
    timeout: int = 180,
) -> tuple[int, dict]:
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}", data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return int(response.status), json.loads(response.read())
    except urllib.error.HTTPError as error:
        raw = error.read().decode(errors="replace")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": raw}
        return int(error.status), payload


def wait_for_server(base_url: str, process: subprocess.Popen[str]) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if process.poll() is not None:
            stdout, stderr = process.communicate(timeout=1)
            raise EvalFailure(
                f"docs server exited early with {process.returncode}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
        try:
            status, _ = request(base_url, "/docs/local-docs-manifest.json", timeout=5)
            if status == 200:
                return
        except OSError:
            pass
        time.sleep(0.1)
    raise EvalFailure(f"timed out waiting for {base_url}")


def evaluate_answer(case: dict, status: int, payload: dict) -> dict:
    answer = str(payload.get("answer") or payload.get("copyText") or "")
    citations = payload.get("citations") if isinstance(payload.get("citations"), list) else []
    citation_sources = {str(citation.get("source", "")) for citation in citations if isinstance(citation, dict)}
    citation_urls = [str(citation.get("url", "")) for citation in citations if isinstance(citation, dict)]
    failures = []

    if status != 200:
        failures.append(f"status {status}: {payload.get('detail') or payload.get('error')}")
        return {
            "id": case["id"],
            "query": case["query"],
            "status": status,
            "ok": False,
            "failures": failures,
            "answer": answer,
            "citations": citations,
        }
    if len(answer.strip()) < 80:
        failures.append("answer is too short")
    if "answer_markdown" in answer or '"citations"' in answer:
        failures.append("answer appears to be raw JSON")
    if not citations:
        failures.append("missing citations")
    if any(url and not url.startswith("/docs/") for url in citation_urls):
        failures.append("citation URL outside /docs")
    for term in case.get("must_mention", []):
        if term.lower() not in answer.lower():
            failures.append(f"missing expected term: {term}")
    expected_sources = set(case.get("expected_sources", []))
    if expected_sources and not expected_sources.intersection(citation_sources):
        failures.append(
            f"missing expected citation source: {', '.join(sorted(expected_sources))}"
        )

    return {
        "id": case["id"],
        "query": case["query"],
        "status": status,
        "ok": not failures,
        "failures": failures,
        "answer": answer,
        "citations": citations,
    }


def run_eval(base_url: str, cases: list[dict], limit: int) -> list[dict]:
    status, manifest = request(base_url, "/docs/local-docs-manifest.json")
    if status != 200 or not manifest.get("local"):
        raise EvalFailure("local docs manifest is unavailable")

    results = []
    for case in cases:
        search_status, search_payload = request(
            base_url,
            f"/docs/api/search?q={urllib.parse.quote(case['query'])}&limit={limit}",
        )
        if search_status != 200 or not search_payload.get("results"):
            results.append(
                {
                    "id": case["id"],
                    "query": case["query"],
                    "status": search_status,
                    "ok": False,
                    "failures": ["canonical search returned no results"],
                    "answer": "",
                    "citations": [],
                }
            )
            continue
        status, payload = request(
            base_url,
            "/docs/api/ask",
            method="POST",
            body={"query": case["query"]},
        )
        results.append(evaluate_answer(case, status, payload))
    return results


def print_report(results: list[dict]) -> None:
    passed = sum(1 for result in results if result["ok"])
    print(f"Docs ask eval: {passed}/{len(results)} passed\n")
    print("| Case | Result | Notes |")
    print("| --- | --- | --- |")
    for result in results:
        notes = "; ".join(result["failures"]) if result["failures"] else "ok"
        print(f"| {result['id']} | {'PASS' if result['ok'] else 'FAIL'} | {notes} |")

    for result in results:
        print(f"\n## {result['id']}")
        print(result["answer"].strip() or "(no answer)")
        if result["citations"]:
            print("\nCitations:")
            for citation in result["citations"]:
                print(
                    f"- {citation.get('title') or citation.get('source')}: "
                    f"{citation.get('url')} ({citation.get('source')})"
                )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", help="Use an already-running docs server.")
    parser.add_argument("--port", type=int, help="Port for a temporary docs server.")
    parser.add_argument(
        "--real-claude",
        action="store_true",
        help="When starting a server, use the real claude binary.",
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        help="Write full eval results to this JSON file.",
    )
    parser.add_argument("--limit", type=int, default=12, help="Filtered docs per case.")
    args = parser.parse_args()

    process: subprocess.Popen[str] | None = None
    temp_dir: tempfile.TemporaryDirectory[str] | None = None
    try:
        if args.base_url:
            base_url = args.base_url.rstrip("/")
        else:
            temp_dir = tempfile.TemporaryDirectory(prefix="workspaces-docs-ask-eval-")
            port = args.port or free_port()
            base_url = f"http://127.0.0.1:{port}"
            env = {
                **os.environ,
                "PYTHONPYCACHEPREFIX": str(Path(temp_dir.name) / "pycache"),
                "WORKSPACES_DOCS_ASK_TIMEOUT_SECONDS": "30",
            }
            if not args.real_claude:
                env["WORKSPACES_DOCS_ASK_CLAUDE_BIN"] = str(
                    REPO_ROOT / "scripts/docs-fake-claude.py"
                )
            process = subprocess.Popen(
                [sys.executable, str(REPO_ROOT / "docs/server.py"), "--port", str(port)],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            wait_for_server(base_url, process)

        results = run_eval(base_url, DEFAULT_CASES, args.limit)
        print_report(results)
        if args.json_output:
            args.json_output.write_text(json.dumps(results, indent=2), encoding="utf-8")
        if any(not result["ok"] for result in results):
            raise SystemExit(1)
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if temp_dir is not None:
            temp_dir.cleanup()


if __name__ == "__main__":
    try:
        main()
    except EvalFailure as error:
        print(f"docs ask eval failed: {error}", file=sys.stderr)
        raise SystemExit(1)
