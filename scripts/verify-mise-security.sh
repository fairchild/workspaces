#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

MISE_EXPECTED_VERSION="v2026.6.0"
MISE_EXPECTED_LINUX_X64_SHA256="9d225e07427b7e05cc4ae7f09f111dfdefdfebb58956513403711935ce313202"
ZIG_VERSION="0.15.2"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

curl_github_api() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  else
    curl -fsSL "$url"
  fi
}

verify_mise_configs() {
  local config relative
  local -a configs=()
  local -a expected=(".mise.toml" "web/.mise.toml")
  local forbidden_regex='(^[[:space:]]*\[(env|hooks)\][[:space:]]*$|trusted_config_paths|^[[:space:]]*(yes|ci)[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$|_[.](source|file)[[:space:]]*=)'

  while IFS= read -r config; do
    relative="${config#$REPO_ROOT/}"
    configs+=("$relative")
  done < <(
    find "$REPO_ROOT" \
      -path "*/.git" -prune -o \
      -path "*/node_modules" -prune -o \
      -path "*/.pnpm-store" -prune -o \
      -name ".mise.toml" -print | sort
  )

  [[ "${configs[*]}" == "${expected[*]}" ]] \
    || fail "unexpected mise config set: ${configs[*]:-(none)}"

  for relative in "${configs[@]}"; do
    if grep -En "$forbidden_regex" "$REPO_ROOT/$relative" >&2; then
      fail "forbidden trust/env directive in $relative"
    fi
  done

  echo "verified mise config allowlist"
}

verify_mise_lock() {
  python3 - <<'PY'
from __future__ import annotations

import re
from pathlib import Path

root = Path.cwd()

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)

root_mise = (root / ".mise.toml").read_text()
settings = re.search(r"(?ms)^\[settings\]\s*(.*?)(?=^\[|\Z)", root_mise)
tools = re.search(r"(?ms)^\[tools\]\s*(.*?)(?=^\[|\Z)", root_mise)
require(settings is not None, ".mise.toml missing [settings]")
require(tools is not None, ".mise.toml missing [tools]")
require(re.search(r"(?m)^lockfile\s*=\s*true\s*$", settings.group(1)) is not None, ".mise.toml must enable lockfile")
require(re.search(r'(?m)^zig\s*=\s*"0\.15\.2"\s*$', tools.group(1)) is not None, ".mise.toml must pin zig 0.15.2")

lock = (root / "mise.lock").read_text()
zig_entries = re.findall(r"(?ms)^\[\[tools\.zig\]\]\s*(.*?)(?=^\[\[|\Z)", lock)
require(len(zig_entries) == 1, "mise.lock must contain exactly one zig entry")
zig = zig_entries[0]
require(re.search(r'(?m)^version\s*=\s*"0\.15\.2"\s*$', zig) is not None, "mise.lock must pin zig 0.15.2")
require(re.search(r'(?m)^backend\s*=\s*"core:zig"\s*$', zig) is not None, "mise.lock must use core:zig")
for platform in ("linux-x64", "macos-arm64"):
    platform_match = re.search(rf'(?m)^"platforms\.{platform}"\s*=\s*\{{(?P<body>[^}}]+)\}}\s*$', zig)
    require(platform_match is not None, f"mise.lock missing zig {platform} entry")
    body = platform_match.group("body")
    require(
        re.search(r'checksum\s*=\s*"sha256:[a-f0-9]{64}"', body) is not None,
        f"mise.lock must pin zig {platform} with a sha256 checksum",
    )
    require(
        re.search(r'url\s*=\s*"https://[^"]+"', body) is not None,
        f"mise.lock must pin zig {platform} with an https URL",
    )
PY

  echo "verified mise.lock"
}

verify_repo_invocations() {
  grep -Fq 'mise exec --locked "zig@$ZIG_VERSION" -- zig' scripts/build-ghosttykit.sh \
    || fail "build-ghosttykit must use locked mise exec"
  grep -Fq 'MISE_CONFIG_FILE=$PROJECT_DIR/.mise.toml' scripts/build-ghosttykit.sh \
    || fail "build-ghosttykit must pin the repo mise config file"
  grep -Fq 'MISE_CONFIG_ROOT=$PROJECT_DIR' scripts/build-ghosttykit.sh \
    || fail "build-ghosttykit must pin the repo mise config root"
  grep -Fq 'MISE_IGNORED_CONFIG_PATHS=$HOME/.config/mise' scripts/build-ghosttykit.sh \
    || fail "build-ghosttykit must ignore global mise config"
  grep -Fq 'mise install --locked zig@0.15.2' scripts/setup \
    || fail "setup must install Zig through locked mise"
  grep -Fq 'path "*/.pnpm-store" -prune' scripts/setup \
    || fail "setup must ignore generated pnpm store directories"

  echo "verified repo mise invocations"
}

verify_latest_mise_pin() {
  require_cmd curl
  require_cmd python3

  local latest_json latest_tag prerelease draft shasum_line
  latest_json="$(curl_github_api https://api.github.com/repos/jdx/mise/releases/latest)"
  latest_tag="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"$latest_json")"
  prerelease="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["prerelease"]).lower())' <<<"$latest_json")"
  draft="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["draft"]).lower())' <<<"$latest_json")"

  [[ "$draft" == "false" ]] || fail "latest mise release is a draft: $latest_tag"
  [[ "$prerelease" == "false" ]] || fail "latest mise release is a prerelease: $latest_tag"
  [[ "$latest_tag" == "$MISE_EXPECTED_VERSION" ]] \
    || fail "sandbox mise pin $MISE_EXPECTED_VERSION is not latest stable $latest_tag"

  grep -Fq "MISE_VERSION='$MISE_EXPECTED_VERSION'" web/src/lib/agent-runtime/vercel-sandbox.ts \
    || fail "sandbox mise version is not pinned to $MISE_EXPECTED_VERSION"
  grep -Fq "MISE_SHA256='$MISE_EXPECTED_LINUX_X64_SHA256'" web/src/lib/agent-runtime/vercel-sandbox.ts \
    || fail "sandbox mise sha256 does not match verifier"
  grep -Fq "sha256sum -c -" web/src/lib/agent-runtime/vercel-sandbox.ts \
    || fail "sandbox must verify mise checksum"
  grep -Fq "mise-latest-linux-x64" web/src/lib/agent-runtime/vercel-sandbox.ts \
    && fail "sandbox must not use moving mise latest URL"

  shasum_line="$(curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_EXPECTED_VERSION}/SHASUMS256.txt" \
    | awk -v asset="./mise-${MISE_EXPECTED_VERSION}-linux-x64" '$2 == asset { print }')"
  [[ "$shasum_line" == "$MISE_EXPECTED_LINUX_X64_SHA256  ./mise-${MISE_EXPECTED_VERSION}-linux-x64" ]] \
    || fail "sandbox mise sha256 does not match upstream SHASUMS256.txt"

  if command -v mise >/dev/null 2>&1; then
    local installed_version
    installed_version="$(mise --version | awk '{print $1}')"
    [[ "$installed_version" == "${MISE_EXPECTED_VERSION#v}" ]] \
      || fail "installed mise $installed_version does not match $MISE_EXPECTED_VERSION"
  fi

  echo "verified latest stable mise pin"
}

verify_locked_zig_exec() {
  if ! command -v mise >/dev/null 2>&1; then
    echo "skipping locked Zig execution: mise not installed"
    return
  fi

  local zig_output
  local cache_dir="${TMPDIR:-/tmp}/workspaces-mise-security-cache"
  mkdir -p "$cache_dir"

  zig_output="$(
    MISE_CONFIG_FILE="$REPO_ROOT/.mise.toml" \
      MISE_CONFIG_ROOT="$REPO_ROOT" \
      MISE_CACHE_DIR="$cache_dir" \
      MISE_IGNORED_CONFIG_PATHS="$HOME/.config/mise${MISE_IGNORED_CONFIG_PATHS:+:$MISE_IGNORED_CONFIG_PATHS}" \
      MISE_TRUSTED_CONFIG_PATHS="$REPO_ROOT${MISE_TRUSTED_CONFIG_PATHS:+:$MISE_TRUSTED_CONFIG_PATHS}" \
      MISE_PARANOID=1 \
      mise exec --locked "zig@$ZIG_VERSION" -- zig version
  )"
  [[ "$zig_output" == "$ZIG_VERSION" ]] \
    || fail "locked Zig exec returned '$zig_output', expected '$ZIG_VERSION'"

  echo "verified locked Zig execution"
}

main() {
  verify_mise_configs
  verify_mise_lock
  verify_repo_invocations
  verify_latest_mise_pin
  verify_locked_zig_exec
}

main "$@"
