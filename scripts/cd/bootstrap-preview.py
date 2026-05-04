#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Interactive bootstrap for preview→validate→promote CD.

Walks you through the setup one step at a time, explains what each value is
for, pastes clickable documentation links, and writes answers to
scripts/cd/.env.bootstrap as it goes. Re-run any time — already-set values
are detected and skipped.

Modes:
  default            interactive dry-run (prompts, but no remote writes)
  --apply            interactive + actually write to GitHub/Cloudflare
  --non-interactive  no prompts; warns on anything missing. Pair with --apply
                     for CI-driven bootstrap once .env.bootstrap is populated.
  --only STEP        run only one step (prereq|vercel|cloudflare|github|validate)
  --force            overwrite secrets that are already set
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import shlex
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent.parent
CD_DIR = Path(__file__).resolve().parent
CONFIG_PATH = CD_DIR / "config.toml"
ENV_PATH = CD_DIR / ".env.bootstrap"
ENV_EXAMPLE_PATH = CD_DIR / ".env.bootstrap.example"


def npx(*args: str) -> list[str]:
    """npx invocation that auto-accepts package installs.

    `--yes` makes npx skip its interactive 'Ok to proceed?' prompt when a
    package isn't locally installed. npm log noise is silenced globally via
    the npm_config_loglevel env var set in main().
    """
    return ["npx", "--yes", *args]


def curl_ok(url: str, timeout: int = 10) -> bool:
    """Silent HTTP GET — returns True on any 2xx, no output."""
    result = subprocess.run(
        ["curl", "-sSf", "--max-time", str(timeout), url],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def git_file_state(rel_path: str) -> str:
    """Return 'untracked' | 'modified' | 'clean' | 'missing' for a repo-relative path."""
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain", "--", rel_path],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "missing"
    status = result.stdout.strip()
    if not status:
        return "clean"
    # porcelain: "XY path" — first char index status, second worktree
    return "untracked" if status.startswith("??") else "modified"


# ---------- terminal output ----------


def _tty() -> bool:
    return sys.stdout.isatty() and os.environ.get("TERM", "") != "dumb"


def hyperlink(url: str, label: str | None = None) -> str:
    """Emit OSC 8 hyperlink if TTY, else 'label (url)' fallback."""
    label = label or url
    if _tty() and not os.environ.get("NO_COLOR"):
        return f"\x1b]8;;{url}\x1b\\{label}\x1b]8;;\x1b\\"
    return f"{label} ({url})" if label != url else url


def _color(text: str, code: str) -> str:
    if _tty() and not os.environ.get("NO_COLOR"):
        return f"\x1b[{code}m{text}\x1b[0m"
    return text


def bold(s: str) -> str:
    return _color(s, "1")


def dim(s: str) -> str:
    return _color(s, "2")


def info(msg: str) -> None:
    print(f"  {msg}")


def ok(msg: str) -> None:
    print(f"  {_color('✓', '32')} {msg}")


def warn(msg: str) -> None:
    print(f"  {_color('!', '33')} {msg}")


def err(msg: str) -> None:
    print(f"  {_color('✗', '31')} {msg}")


def step(n: int, title: str) -> None:
    print(f"\n{bold(f'[{n}] {title}')}")


def teach(msg: str) -> None:
    """Educational context — italic-ish dim color."""
    print(f"  {dim(msg)}")


# ---------- prompting ----------


@dataclass
class Prompt:
    interactive: bool

    def yes_no(self, question: str, default: bool = False) -> bool:
        if not self.interactive:
            return default
        suffix = "[Y/n]" if default else "[y/N]"
        while True:
            try:
                resp = input(f"  → {question} {suffix} ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print()
                return False
            if not resp:
                return default
            if resp in ("y", "yes"):
                return True
            if resp in ("n", "no"):
                return False

    def secret(self, label: str) -> str | None:
        """Prompt for a hidden value. Returns None if skipped or non-interactive."""
        if not self.interactive:
            return None
        try:
            value = getpass.getpass(f"  → {label} (hidden, Enter to skip): ")
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        return value.strip() or None

    def await_done(self, instruction: str) -> bool:
        """Show instruction, wait for user to press Enter (confirming done)."""
        if not self.interactive:
            return False
        try:
            input(f"  → {instruction} press Enter when done (or Ctrl-C to skip): ")
            return True
        except (EOFError, KeyboardInterrupt):
            print()
            return False


# ---------- .env.bootstrap management ----------


def load_env_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip().strip('"').strip("'")
    return out


def save_env_var(path: Path, key: str, value: str) -> None:
    """Idempotently set key=value in the .env.bootstrap file."""
    path.touch(exist_ok=True)
    lines = path.read_text().splitlines()
    quoted = shlex.quote(value) if any(c in value for c in " \t\"'$`\\") else value
    new_line = f"{key}={quoted}"
    replaced = False
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.split("=", 1)[0].strip() == key and "=" in stripped and not stripped.startswith("#"):
            out.append(new_line)
            replaced = True
        else:
            out.append(line)
    if not replaced:
        if out and out[-1].strip():
            out.append("")
        out.append(new_line)
    path.write_text("\n".join(out) + "\n")


def mask(value: str) -> str:
    if len(value) <= 8:
        return "****"
    return f"{value[:4]}…{value[-4:]}"


# ---------- config ----------


def load_config(path: Path) -> dict:
    return tomllib.loads(path.read_text())


# ---------- CLI execution ----------


@dataclass
class Runner:
    apply: bool

    def run(
        self,
        cmd: list[str],
        *,
        cwd: Path | None = None,
        stdin: str | None = None,
        capture: bool = True,
        check: bool = True,
        quiet: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        if not quiet:
            info(dim(f"$ {_redact(cmd)}" + (f"  (cwd={cwd.relative_to(ROOT)})" if cwd else "")))
        if not self.apply and _is_mutation(cmd):
            return subprocess.CompletedProcess(cmd, 0, "(dry-run)\n", "")
        return subprocess.run(
            cmd,
            cwd=cwd,
            input=stdin,
            text=True,
            capture_output=capture,
            check=check,
        )


def _redact(cmd: list[str]) -> str:
    out: list[str] = []
    i = 0
    while i < len(cmd):
        tok = cmd[i]
        out.append(tok)
        if tok == "--body" and i + 1 < len(cmd):
            out.append("***")
            i += 2
            continue
        i += 1
    return " ".join(out)


_MUTATING_PATTERNS: list[tuple[str, ...]] = [
    ("gh", "secret", "set"),
    ("gh", "secret", "remove"),
    ("wrangler", "secret", "put"),
    ("wrangler", "secret", "delete"),
    ("vercel", "link"),
]


def _is_mutation(cmd: list[str]) -> bool:
    if "wrangler" in cmd and "deploy" in cmd and "--dry-run" not in cmd:
        return True
    stream = tuple(cmd)
    for pat in _MUTATING_PATTERNS:
        for i in range(len(stream) - len(pat) + 1):
            if stream[i : i + len(pat)] == pat:
                return True
    return False


# ---------- step 1: prereqs ----------


def step_prereqs(prompt: Prompt) -> bool:
    step(1, "Prerequisites")
    problems: list[str] = []
    for bin_name, install_hint in [
        ("gh", "brew install gh"),
        ("wrangler", "npm i -g wrangler (or rely on npx)"),
        ("curl", "preinstalled on macOS/Linux"),
    ]:
        if shutil.which(bin_name):
            ok(f"{bin_name} present")
        else:
            err(f"{bin_name} not found — install: {install_hint}")
            problems.append(bin_name)
    if not (shutil.which("vercel") or shutil.which("npx")):
        err("neither vercel nor npx on PATH — install Node.js")
        problems.append("vercel/npx")
    else:
        ok("vercel/npx present")

    try:
        subprocess.run(["gh", "auth", "status"], check=True, capture_output=True)
        ok("gh is authenticated")
    except (subprocess.CalledProcessError, FileNotFoundError):
        err(f"gh not authenticated — run: {bold('gh auth login')}")
        problems.append("gh-auth")

    if problems:
        err("Fix the above before continuing.")
        return False

    # .env.bootstrap existence
    if ENV_PATH.exists():
        ok(f".env.bootstrap exists at {ENV_PATH.relative_to(ROOT)}")
    else:
        warn(f".env.bootstrap does not exist at {ENV_PATH.relative_to(ROOT)}")
        teach(
            "This file stores your tokens and per-worker preview secrets locally "
            "so re-runs are painless. It's gitignored via .env.*"
        )
        if prompt.yes_no(f"Create it from {ENV_EXAMPLE_PATH.name}?", default=True):
            shutil.copy(ENV_EXAMPLE_PATH, ENV_PATH)
            ok(f"created {ENV_PATH.relative_to(ROOT)}")
        else:
            warn("Skipping creation — prompts later will not be persisted.")
    return True


# ---------- step 2: vercel ----------


def vercel_project_file(project_dir: Path) -> Path:
    return project_dir / ".vercel" / "project.json"


def read_vercel_ids(project_dir: Path) -> tuple[str, str] | None:
    f = vercel_project_file(project_dir)
    if not f.exists():
        return None
    data = json.loads(f.read_text())
    org = data.get("orgId") or data.get("teamId")
    project = data.get("projectId")
    return (org, project) if org and project else None


def step_vercel(
    runner: Runner,
    prompt: Prompt,
    env: dict[str, str],
    cfg: dict,
) -> tuple[str, str] | None:
    step(2, "Vercel link + Git auto-deploy guard")
    vercel_cfg = cfg.get("vercel", {})
    project_dir = ROOT / vercel_cfg.get("project_dir", "web")

    teach(
        "CD needs a Vercel token to deploy your Next.js app, plus the project's "
        "orgId/projectId. After `vercel link`, both IDs land in web/.vercel/project.json."
    )

    token = env.get("VERCEL_TOKEN")
    if not token:
        warn("VERCEL_TOKEN not set.")
        info(f"Create one at {hyperlink('https://vercel.com/account/tokens', 'vercel.com/account/tokens')}")
        teach("Recommended: scope=your team, expiration=no expiration, name=github-actions-cd")
        token = prompt.secret("Paste VERCEL_TOKEN")
        if token:
            save_env_var(ENV_PATH, "VERCEL_TOKEN", token)
            env["VERCEL_TOKEN"] = token
            ok(f"saved to .env.bootstrap ({mask(token)})")
        else:
            warn("Skipped. Vercel link cannot run without a token.")
            return None
    else:
        ok(f"VERCEL_TOKEN present ({mask(token)})")

    ids = read_vercel_ids(project_dir)
    if ids:
        ok(f"Vercel already linked (orgId={mask(ids[0])}, projectId={mask(ids[1])})")
    else:
        warn("Vercel project not linked yet.")
        teach("`vercel link` is interactive. It writes web/.vercel/project.json.")
        if runner.apply:
            runner.run(
                npx("vercel@51", "link", "--yes", "--token", token),
                cwd=project_dir,
                capture=False,
                quiet=True,
            )
            ids = read_vercel_ids(project_dir)
        else:
            info(dim("(dry-run: would run `npx vercel@51 link --yes`)"))

    if ids:
        ok(f"orgId={mask(ids[0])}  projectId={mask(ids[1])}")

    # Disable Vercel's git auto-deployments in code (no dashboard step).
    print()
    info(bold("Disable Vercel Git auto-deployments (via vercel.json)"))
    teach(
        "Sets `git.deploymentEnabled = false` in web/vercel.json so Vercel's Git "
        "integration stays connected for metadata without auto-deploying pushes or PRs. "
        "GitHub Actions owns PR previews and production promotion."
    )
    ensure_vercel_json_disables_git_auto_deploys(runner, prompt, project_dir)

    return ids


def ensure_vercel_json_disables_git_auto_deploys(
    runner: Runner,
    prompt: Prompt,
    project_dir: Path,
) -> None:
    """Idempotently set git.deploymentEnabled = false in vercel.json.

    Local file write — gated on runner.apply so dry-run mode shows the intent
    without modifying the working tree.
    """
    vjson_path = project_dir / "vercel.json"
    rel = vjson_path.relative_to(ROOT)

    is_new = not vjson_path.exists()
    if is_new:
        data: dict = {}
    else:
        try:
            data = json.loads(vjson_path.read_text())
        except json.JSONDecodeError as e:
            err(f"{rel} exists but is not valid JSON: {e}")
            return

    git_block = data.setdefault("git", {})
    if not isinstance(git_block, dict):
        err(f"{rel} has non-object `git` config; update it manually")
        return

    if git_block.get("deploymentEnabled") is False:
        ok(f"{rel} already disables Vercel Git auto-deployments")
        return

    if is_new:
        # Add $schema so editors get autocomplete and validation.
        # https://vercel.com/docs/project-configuration/git-configuration
        data["$schema"] = "https://openapi.vercel.sh/vercel.json"
        info(f"will create {rel} with `git.deploymentEnabled = false`")
    else:
        info(f"will set `git.deploymentEnabled = false` in {rel}")

    if not runner.apply:
        info(dim("(dry-run: no file write)"))
        return

    git_block["deploymentEnabled"] = False
    # Use tab indent to match web/biome.jsonc formatter config — biome runs
    # against web/**/*.json and will reject space-indented output on commit.
    vjson_path.write_text(json.dumps(data, indent="\t") + "\n")
    ok(f"updated {rel}")

    offer_commit_vercel_json(prompt, str(rel))


def offer_commit_vercel_json(prompt: Prompt, rel: str) -> None:
    """If vercel.json isn't committed, offer to commit it (or print the command)."""
    state = git_file_state(rel)
    commit_msg = "chore(web): disable Vercel git auto-deployments"
    commit_cmd = f'git add {rel} && git commit -m "{commit_msg}"'

    if state == "clean":
        ok(f"{rel} already committed")
        return
    if state == "missing":
        warn(f"{rel} not visible to git (is the working tree healthy?)")
        return

    teach(
        "Until this file reaches main, Vercel's git integration will continue to "
        "auto-deploy pushes and PRs."
    )
    if prompt.interactive and prompt.yes_no(f"Commit {rel} now?", default=True):
        try:
            subprocess.run(["git", "add", rel], cwd=ROOT, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", commit_msg],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            ok(f"committed {rel} (run `git push` to share with the team)")
        except subprocess.CalledProcessError as e:
            warn(f"auto-commit failed — run manually:  {bold(commit_cmd)}")
            if e.stderr:
                info(dim(e.stderr.strip()[:200]))
    else:
        info(f"Run when ready:  {bold(commit_cmd)}")


# ---------- step 3: cloudflare preview secrets ----------


def list_worker_preview_secrets(worker_dir: Path) -> set[str]:
    try:
        result = subprocess.run(
            npx("wrangler@4", "secret", "list", "--env", "preview"),
            cwd=worker_dir,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return set()
        start = result.stdout.find("[")
        if start < 0:
            return set()
        parsed = json.loads(result.stdout[start:])
        return {item["name"] for item in parsed if isinstance(item, dict) and "name" in item}
    except (json.JSONDecodeError, KeyError):
        return set()


def step_cloudflare(
    runner: Runner,
    prompt: Prompt,
    env: dict[str, str],
    cfg: dict,
    *,
    force: bool,
) -> None:
    step(3, "Cloudflare Worker preview secrets")
    teach(
        "Each worker's preview env has its own secret namespace. We check what's "
        "already set via `wrangler secret list --env preview` so re-runs skip "
        "already-configured values."
    )

    for w in cfg.get("workers", []):
        worker_dir = ROOT / w["dir"]
        hints = w.get("preview_secret_hints", {})
        print()
        info(bold(f"worker: {w['dir']}"))
        existing = list_worker_preview_secrets(worker_dir)

        for name in w.get("preview_secrets", []):
            env_key = f"PW_{name}"

            if name in existing and not force:
                ok(f"{name} already set on preview env (skip)")
                continue

            value = env.get(env_key)
            if not value:
                warn(f"{name} not in env (expected as {env_key})")
                hint = hints.get(name)
                if hint:
                    teach(hint)
                else:
                    teach(
                        f"Worker secret for preview. See "
                        f"{hyperlink('https://developers.cloudflare.com/workers/configuration/secrets/', 'Cloudflare Workers Secrets docs')}."
                    )
                value = prompt.secret(f"Paste value for {name}")
                if value:
                    save_env_var(ENV_PATH, env_key, value)
                    env[env_key] = value
                    ok(f"saved {env_key} to .env.bootstrap ({mask(value)})")
                else:
                    warn(f"{name}: skipped")
                    continue

            runner.run(
                npx("wrangler@4", "secret", "put", name, "--env", "preview"),
                cwd=worker_dir,
                stdin=value + "\n",
                capture=True,
                check=True,
            )
            ok(f"{name} {'set' if runner.apply else '(would set)'} on preview env")


# ---------- step 4: github secrets ----------


def list_github_secrets(repo: str) -> set[str]:
    try:
        result = subprocess.run(
            ["gh", "secret", "list", "--repo", repo, "--json", "name"],
            check=True,
            capture_output=True,
            text=True,
        )
        return {item["name"] for item in json.loads(result.stdout)}
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return set()


def push_github_secret(runner: Runner, repo: str, name: str, value: str) -> None:
    runner.run(
        ["gh", "secret", "set", name, "--repo", repo],
        stdin=value,
        capture=True,
        check=True,
    )
    ok(f"{name} {'set' if runner.apply else '(would set)'} on {repo}")


def step_github(
    runner: Runner,
    prompt: Prompt,
    env: dict[str, str],
    cfg: dict,
    vercel_ids: tuple[str, str] | None,
    *,
    force: bool,
) -> None:
    step(4, "GitHub Actions repo secrets")
    repo = cfg["repo"]["slug"]
    repo_secrets_url = f"https://github.com/{repo}/settings/secrets/actions"
    teach(
        f"These are the secrets GitHub Actions needs to run cd.yml. "
        f"Manage them at {hyperlink(repo_secrets_url, 'repo settings → secrets')}"
    )

    existing = list_github_secrets(repo)
    gh_cfg = cfg.get("github_secrets", {})

    hints = {
        "VERCEL_TOKEN": (
            "https://vercel.com/account/tokens",
            "same token as step 2",
        ),
        "CLOUDFLARE_API_TOKEN": (
            "https://dash.cloudflare.com/profile/api-tokens",
            "'Edit Cloudflare Workers' template + add 'R2 Storage:Edit'",
        ),
        "CLOUDFLARE_ACCOUNT_ID": (
            "https://dash.cloudflare.com/",
            "sidebar on any account page, or `wrangler whoami`",
        ),
        "VERCEL_AUTOMATION_BYPASS_SECRET": (
            "https://vercel.com/docs/deployment-protection/methods-to-bypass-deployment-protection/protection-bypass-automation",
            "Vercel dashboard → Project → Settings → Deployment Protection → Protection Bypass for Automation → Add Secret. Lets Playwright/Lighthouse reach preview URLs that are otherwise gated behind the Vercel login wall.",
        ),
    }

    for name in gh_cfg.get("from_env", []):
        if name in existing and not force:
            ok(f"{name} already set on {repo} (skip)")
            continue

        value = env.get(name)
        if not value:
            warn(f"{name} not set.")
            link_url, tip = hints.get(name, ("", ""))
            if link_url:
                info(f"Get it at {hyperlink(link_url)}")
            if tip:
                teach(tip)
            value = prompt.secret(f"Paste {name}")
            if value:
                save_env_var(ENV_PATH, name, value)
                env[name] = value
                ok(f"saved to .env.bootstrap ({mask(value)})")
            else:
                warn(f"{name}: skipped")
                continue

        push_github_secret(runner, repo, name, value)

    for name in gh_cfg.get("from_vercel_link", []):
        if name in existing and not force:
            ok(f"{name} already set on {repo} (skip)")
            continue
        if not vercel_ids:
            warn(
                f"{name}: Vercel not linked yet — re-run `--only vercel` then `--only github`."
            )
            continue
        value = vercel_ids[0] if name == "VERCEL_ORG_ID" else vercel_ids[1]
        push_github_secret(runner, repo, name, value)


# ---------- step 5: validate ----------


def validate_worker_wiring(runner: Runner, worker_dir: Path) -> bool:
    try:
        runner.run(
            npx("wrangler@4", "deploy", "--env", "preview", "--dry-run"),
            cwd=worker_dir,
            capture=True,
            check=True,
            quiet=True,
        )
        ok(f"{worker_dir.name}: wrangler --dry-run deploy OK")
        return True
    except subprocess.CalledProcessError as e:
        err(f"{worker_dir.name}: dry-run failed")
        print(e.stderr or e.stdout)
        return False


def deploy_preview_real(runner: Runner, worker_dir: Path) -> bool:
    """Run a real `wrangler deploy --env preview`.

    With `custom_domain = true` in `[[env.preview.routes]]`, wrangler itself
    provisions the custom hostname + DNS on first deploy — closing the gap
    where a dry-run passes but the health URL is unreachable.
    """
    try:
        runner.run(
            npx("wrangler@4", "deploy", "--env", "preview"),
            cwd=worker_dir,
            capture=True,
            check=True,
        )
        return True
    except subprocess.CalledProcessError as e:
        err(f"deploy failed: {(e.stderr or e.stdout or '').strip()[:300]}")
        return False


def vercel_env_keys_from_payload(payload: object) -> set[str] | None:
    if isinstance(payload, dict):
        envs = payload.get("envs", [])
    elif isinstance(payload, list):
        envs = payload
    else:
        return None

    return {
        item["key"]
        for item in envs
        if isinstance(item, dict) and isinstance(item.get("key"), str)
    }


def parse_vercel_env_keys(raw: str) -> set[str] | None:
    text = raw.strip()
    starts = [idx for idx in (text.find("{"), text.find("[")) if idx >= 0]
    if not starts:
        return None

    try:
        payload = json.loads(text[min(starts) :])
    except json.JSONDecodeError:
        return None
    return vercel_env_keys_from_payload(payload)


def list_vercel_env_keys_via_api(env: dict[str, str], target: str) -> set[str] | None:
    token = env.get("VERCEL_TOKEN")
    project_id = env.get("VERCEL_PROJECT_ID")
    org_id = env.get("VERCEL_ORG_ID")
    if not token or not project_id:
        return None

    query = urlencode({"target": target, **({"teamId": org_id} if org_id else {})})
    url = f"https://api.vercel.com/v10/projects/{project_id}/env?{query}"
    request = Request(url)
    request.add_header("Authorization", f"Bearer {token}")
    try:
        with urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
        return None

    return vercel_env_keys_from_payload(payload)


def list_vercel_env_keys(
    project_dir: Path,
    target: str,
    env: dict[str, str],
) -> set[str] | None:
    try:
        result = subprocess.run(
            npx("vercel@51", "env", "ls", target, "--format", "json"),
            cwd=project_dir,
            check=True,
            capture_output=True,
            text=True,
        )
        keys = parse_vercel_env_keys(result.stdout)
        if keys is not None:
            return keys
    except (subprocess.CalledProcessError, FileNotFoundError):
        return list_vercel_env_keys_via_api(env, target)
    return list_vercel_env_keys_via_api(env, target)


def step_validate(
    runner: Runner,
    prompt: Prompt,
    cfg: dict,
    env: dict[str, str],
) -> bool:
    step(5, "Validate wiring")
    teach(
        "Checks Vercel runtime env, dry-runs `wrangler deploy --env preview`, "
        "and hits each preview /health URL."
    )
    all_ok = True

    vercel_cfg = cfg.get("vercel", {})
    project_dir = ROOT / vercel_cfg.get("project_dir", "web")
    required_env = vercel_cfg.get("runtime_env", [])
    if required_env:
        info(bold("Vercel runtime env"))
        for target in ("preview", "production"):
            existing = list_vercel_env_keys(project_dir, target, env)
            if existing is None:
                warn(f"could not list Vercel {target} env vars")
                all_ok = False
                continue
            missing = [name for name in required_env if name not in existing]
            if missing:
                warn(f"{target}: missing {', '.join(missing)}")
                all_ok = False
            else:
                ok(f"{target}: required auth env present")

    for w in cfg.get("workers", []):
        worker_dir = ROOT / w["dir"]
        if not validate_worker_wiring(runner, worker_dir):
            all_ok = False
            continue
        url = w.get("preview_health_url")
        if not url:
            continue
        if curl_ok(url):
            ok(f"health OK: {url}")
            continue

        # Dry-run passed but health is unreachable — offer a real deploy to
        # register the custom domain / DNS (works when wrangler.toml has
        # custom_domain = true on the preview route).
        warn(f"health not reachable: {url}")
        if not runner.apply:
            info(dim("(dry-run: skipping real deploy offer)"))
            continue
        if not prompt.interactive:
            info(dim("(non-interactive: run `--only validate --apply` interactively to auto-deploy)"))
            continue
        teach(
            "A real `wrangler deploy --env preview` provisions DNS for any "
            "`custom_domain` routes declared in wrangler.toml."
        )
        if not prompt.yes_no(f"Run a real deploy of {w['dir']} now?", default=True):
            continue
        if not deploy_preview_real(runner, worker_dir):
            all_ok = False
            continue
        if curl_ok(url):
            ok(f"health OK after deploy: {url}")
        else:
            warn(
                "health still not reachable after deploy. "
                "Check DNS for the parent zone, then try: "
                f"{bold(f'npx wrangler@4 deployments list --env preview')}"
            )
    return all_ok


# ---------- step 6: final summary ----------


def current_branch() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip() or "main"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "main"


def step_summary(
    apply: bool,
    cfg: dict,
    expected_gh_secrets: list[str],
) -> None:
    step(6, "Verify + what's left")
    repo = cfg["repo"]["slug"]

    # 1. GH secrets — verified via API, not dashboard eyeballing.
    info(bold("GitHub Actions secrets"))
    existing = list_github_secrets(repo)
    if existing:
        missing = [s for s in expected_gh_secrets if s not in existing]
        for s in expected_gh_secrets:
            (ok if s in existing else warn)(f"{s} {'present' if s in existing else 'MISSING'}")
        if missing:
            warn(f"Re-run: {bold(f'uv run scripts/cd/bootstrap-preview.py --apply --only github')}")
    else:
        warn(
            "Could not read secrets via gh (auth or permissions issue). "
            f"Check manually: {hyperlink(f'https://github.com/{repo}/settings/secrets/actions', f'{repo} secrets')}"
        )
    print()

    # 2. Vercel Git auto-deploy guard
    vjson_state = git_file_state("web/vercel.json")
    info(bold("Vercel Git auto-deploy guard"))
    if vjson_state == "clean":
        ok("web/vercel.json committed — guard reaches main on next push")
    elif vjson_state in ("untracked", "modified"):
        commit_cmd = 'git add web/vercel.json && git commit -m "chore(web): disable Vercel git auto-deployments"'
        warn(f"web/vercel.json not committed ({vjson_state}). Run: {bold(commit_cmd)}")
    else:
        warn("web/vercel.json missing — re-run `--only vercel --apply`")
    print()

    # 3. First CD run — CLI + dashboard
    branch = current_branch()
    info(bold("First CD run"))
    run_cmd = f"gh workflow run cd.yml --ref {branch}"
    tail_cmd = 'gh run watch $(gh run list --workflow cd.yml --limit 1 --json databaseId -q ".[0].databaseId")'
    info(f"  CLI:  {bold(run_cmd)}")
    info(f"  Tail: {bold(tail_cmd)}")
    info(
        f"  UI:   {hyperlink(f'https://github.com/{repo}/actions/workflows/cd.yml', 'CD workflow')}"
        f" → Run workflow → `{branch}`"
    )
    teach("Watch preview-web output the *.vercel.app URL, then validators run against it.")
    print()

    # 4. Only surface DNS if adding a new preview route in the future — this
    # isn't a blocker for the standard flow (bootstrap auto-registers DNS for
    # existing custom_domain routes via step 5's real-deploy offer).
    teach(
        "Adding a new preview route later? Declare it with `custom_domain = true` in "
        "the worker's wrangler.toml and re-run `--only validate --apply` — wrangler "
        "will register DNS on the next deploy."
    )
    print()

    if not apply:
        warn(f"Dry-run finished. Re-run with {bold('--apply')} to actually write.")
    else:
        ok("Bootstrap complete.")


# ---------- main ----------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Interactive bootstrap for preview→validate→promote CD.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--apply", action="store_true", help="Actually write (default: dry-run).")
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Skip prompts; warn on missing values. Use in CI.",
    )
    parser.add_argument("--force", action="store_true", help="Overwrite existing secrets.")
    parser.add_argument(
        "--only",
        choices=["prereq", "vercel", "cloudflare", "github", "validate"],
        help="Run only this step.",
    )
    args = parser.parse_args()

    # Silence npm deprecation-warning walls from `npx` package installs.
    # Applies to every subprocess we spawn since we pass os.environ through.
    os.environ.setdefault("npm_config_loglevel", "error")
    os.environ.setdefault("npm_config_fund", "false")
    os.environ.setdefault("npm_config_audit", "false")

    cfg = load_config(CONFIG_PATH)
    env = {**os.environ, **load_env_file(ENV_PATH)}
    prompt = Prompt(interactive=not args.non_interactive)
    runner = Runner(apply=args.apply)

    print(bold("CD Preview Bootstrap"))
    teach("Walks you through preview→validate→promote CD setup.")
    teach(f"Mode: {'APPLY (will write)' if args.apply else 'DRY-RUN (no writes)'}"
          f" · {'interactive' if prompt.interactive else 'non-interactive'}")

    only = args.only

    if only in (None, "prereq"):
        if not step_prereqs(prompt):
            return 1
        env = {**os.environ, **load_env_file(ENV_PATH)}

    vercel_ids: tuple[str, str] | None = None
    if only in (None, "vercel"):
        vercel_ids = step_vercel(runner, prompt, env, cfg)
        env = {**os.environ, **load_env_file(ENV_PATH)}
    else:
        vercel_ids = read_vercel_ids(ROOT / cfg.get("vercel", {}).get("project_dir", "web"))

    if only in (None, "cloudflare"):
        step_cloudflare(runner, prompt, env, cfg, force=args.force)
        env = {**os.environ, **load_env_file(ENV_PATH)}

    if only in (None, "github"):
        step_github(runner, prompt, env, cfg, vercel_ids, force=args.force)

    validate_ok = True
    if only in (None, "validate"):
        validate_ok = step_validate(runner, prompt, cfg, env)

    if only is None:
        gh_cfg = cfg.get("github_secrets", {})
        expected_gh = [*gh_cfg.get("from_env", []), *gh_cfg.get("from_vercel_link", [])]
        step_summary(args.apply, cfg, expected_gh)

    return 0 if validate_ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n  interrupted.")
        sys.exit(130)
