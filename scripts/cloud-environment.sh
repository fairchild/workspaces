#!/bin/bash
# Installs what a Claude Code cloud environment needs for this repository and its base image
# lacks. The environment's setup script fetches this file from main and runs it as root before
# the snapshot that serves later sessions (docs/development/remote-sessions.md). Setup must exit 0
# and finish in about five minutes, so each step is time-boxed and fail-soft, and records its
# outcome in $state for scripts/cloud-session-start.sh to report in the session.
set -u

export state=/var/log/workspaces-cloud-setup
export repo=/home/user/workspaces
export raw=https://raw.githubusercontent.com/fairchild/workspaces/main
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

export mise_version=v2026.11.5
export mise_sha256=7a5b051d6f17d335c502f8047a5175cf3103f347d91942771c60da4e302ebcb0
export prek_version=0.3.4
export swift_format_version=604.0.0
export swift_format_sha256=90c1263e0a1f4cd7ec4242cb7c1d79433badb7f03c01bf2b0dfcb592d0986801
export ghcr_anonymous_token=QQ==

main() {
  export -f fetch_verified install_mise keep_mise_tasks_from_installing_tools install_prek \
    install_swift_format install_playwright pinned_playwright_version warm_pnpm_store

  mkdir -p "$state"
  : >"$state/status"

  step install_mise 60 &
  step install_prek 60 &
  step install_swift_format 60 &
  step install_playwright 200 &
  step warm_pnpm_store 180 &
  wait
}

step() {
  local name="$1" limit="$2" started=$SECONDS outcome=failed
  if timeout -k 5 "$limit" bash -ec "$name" >"$state/$name.log" 2>&1; then
    outcome=ok
  fi
  echo "$outcome $name $((SECONDS - started))s" >>"$state/status"
}

fetch_verified() {
  local url="$1" sha256="$2" file="$3"
  shift 3
  curl -fsSL "$@" -o "$file" "$url"
  echo "$sha256  $file" | sha256sum -c -
}

install_mise() {
  fetch_verified "https://github.com/jdx/mise/releases/download/$mise_version/mise-$mise_version-linux-x64" \
    "$mise_sha256" /tmp/mise
  install -m 755 /tmp/mise /usr/local/bin/mise
  rm -f /tmp/mise
  keep_mise_tasks_from_installing_tools
}

keep_mise_tasks_from_installing_tools() {
  mkdir -p /etc/mise
  printf '[settings.task]\nrun_auto_install = false\n' >/etc/mise/config.toml
}

install_prek() {
  UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --force "prek==$prek_version"
}

install_swift_format() {
  fetch_verified "https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:$swift_format_sha256" \
    "$swift_format_sha256" /tmp/swift-format.tar.gz -H "Authorization: Bearer $ghcr_anonymous_token"
  tar -xzf /tmp/swift-format.tar.gz -O "swift-format/$swift_format_version/bin/swift-format" \
    >/usr/local/bin/swift-format
  chmod 755 /usr/local/bin/swift-format
  rm -f /tmp/swift-format.tar.gz
}

install_playwright() {
  local lockfile version
  for lockfile in web-next/pnpm-lock.yaml web/pnpm-lock.yaml; do
    version="$(pinned_playwright_version "$lockfile")"
    [[ -n "$version" ]]
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers npx -y "playwright@$version" install --with-deps chromium
  done
}

pinned_playwright_version() {
  { cat "$repo/$1" 2>/dev/null || curl -fsSL "$raw/$1"; } \
    | sed -n "s/^  '@playwright\/test@\(.*\)':$/\1/p" | head -n 1
}

warm_pnpm_store() {
  local dir
  corepack enable
  for dir in web-next web; do
    (cd "$repo/$dir" && CI=1 pnpm fetch)
  done
}

main
exit 0
