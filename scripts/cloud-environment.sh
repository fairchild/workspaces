#!/bin/bash
# Installs what a Claude Code cloud environment needs for this repository and its base image
# lacks. The environment's setup script fetches this file from main and runs it as root, and the
# snapshot taken afterward serves later sessions (docs/development/remote-sessions.md).
#
# Every step is time-boxed and fail-soft: setup must exit 0 or sessions fail to start, and past
# about five minutes nothing is cached. Each outcome lands in $state, where
# scripts/cloud-session-start.sh reads it, so a failed step is named in the session.
set -u

export state=/var/log/workspaces-cloud-setup
export repo=/home/user/workspaces
export raw=https://raw.githubusercontent.com/fairchild/workspaces/main
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# Kept in step with the repo's other pins by scripts/mise-pin-refresh.py.
export mise_version=v2026.10.19
export mise_sha256=3162760f40b6b5f706c60641e4ef5ee7322bc6c54f72fc26a7111b337aa18d9d
export prek_version=0.3.4
# The version CI installs, from Homebrew's x86_64_linux bottle.
export swift_format_version=604.0.0
export swift_format_sha256=90c1263e0a1f4cd7ec4242cb7c1d79433badb7f03c01bf2b0dfcb592d0986801

# Tasks stay runnable without their [tools]: .mise.toml's zig only builds GhosttyKit, and
# installing it would need ziglang.org and rewrite mise.lock in the session's checkout.
install_mise() {
  local file=/tmp/mise
  curl -fsSL -o "$file" "https://github.com/jdx/mise/releases/download/$mise_version/mise-$mise_version-linux-x64"
  echo "$mise_sha256  $file" | sha256sum -c -
  install -m 755 "$file" /usr/local/bin/mise
  rm -f "$file"
  mkdir -p /etc/mise
  printf '[settings.task]\nrun_auto_install = false\n' >/etc/mise/config.toml
}

install_prek() {
  UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --force "prek==$prek_version"
}

# A self-contained 41 MB bottle, where the swift.org toolchain is 1.1 GB and nothing else in it
# helps: this package's targets need macOS to compile. QQ== is ghcr.io's anonymous bearer token.
install_swift_format() {
  local file=/tmp/swift-format.tar.gz
  curl -fsSL -H 'Authorization: Bearer QQ==' -o "$file" \
    "https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:$swift_format_sha256"
  echo "$swift_format_sha256  $file" | sha256sum -c -
  tar -xzf "$file" -O "swift-format/$swift_format_version/bin/swift-format" >/usr/local/bin/swift-format
  chmod 755 /usr/local/bin/swift-format
  rm -f "$file"
}

# The browser each lockfile pins, read from the lockfile so a Playwright bump needs no edit here.
install_playwright() {
  local lockfile version
  for lockfile in web-next/pnpm-lock.yaml web/pnpm-lock.yaml; do
    version="$({ cat "$repo/$lockfile" 2>/dev/null || curl -fsSL "$raw/$lockfile"; } \
      | sed -n "s/^  '@playwright\/test@\(.*\)':$/\1/p" | head -n 1)"
    [[ -n "$version" ]]
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers npx -y "playwright@$version" install --with-deps chromium
  done
}

# Fills the pnpm store so the session's install has nothing left to download. The clone exists by
# now in the runs seen so far, and the session's own install covers the case where it doesn't.
fetch_packages() {
  local dir
  corepack enable
  for dir in web-next web; do
    (cd "$repo/$dir" && CI=1 pnpm fetch)
  done
}

export -f install_mise install_prek install_swift_format install_playwright fetch_packages

step() {
  local name="$1" limit="$2" started=$SECONDS outcome=failed
  if timeout "$limit" bash -ec "$name" >"$state/$name.log" 2>&1; then
    outcome=ok
  fi
  echo "$outcome $name $((SECONDS - started))s" >>"$state/status"
}

mkdir -p "$state"
: >"$state/status"

step install_mise 60 &
step install_prek 60 &
step install_swift_format 60 &
step install_playwright 240 &
step fetch_packages 200 &
wait

exit 0
