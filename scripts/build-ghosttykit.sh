#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# build-ghosttykit.sh
#
# Builds the pinned GhosttyKit xcframework used by this repository's
# Swift Package Manager (SwiftPM) binary target at
# `Frameworks/GhosttyKit.xcframework`.
#
# Why this exists in Workspaces:
# - The app embeds libghostty for terminal rendering/input.
# - We pin a Ghostty commit so local + continuous integration (CI) builds are
#   reproducible.
# - This script standardizes where Ghostty comes from and where the framework
#   lands so `swift build` and Xcode open/build work reliably.
#
# Usage:
#   ./scripts/build-ghosttykit.sh [--purge-cache]
#
# Flags:
#   --purge-cache     Delete the per-commit Zig cache before building. The
#                     remedy when the shared cache has been polluted by a
#                     build for another platform or macOS version (see
#                     assert_macos_deployment_target below).
#
# Optional environment variables:
#   GHOSTTY_DIR       Existing Ghostty checkout (must already be at pinned commit).
#   GHOSTTY_CACHE_DIR Cache root for auto-cloned Ghostty checkout.
#   GHOSTTY_ZIG_BIN   Zig executable to use for building Ghostty.
#   GHOSTTY_ZIG_CACHE_DIR Zig cache root for building Ghostty.
#   GHOSTTY_ARCH_DIAGNOSTICS  Set to 0 to silence the post-build architecture
#                     report (host arch, zig binary arch, xcframework slice
#                     info). Defaults to 1. Added to chase down a "no such
#                     module 'GhosttyKit'" failure that turned out to be a
#                     Rosetta/x86_64 zig producing a slice that doesn't match
#                     an arm64 build target; see prepare_slice_arch_patch()
#                     below for the fix, kept on to catch a regression.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/Frameworks"

# Pinned versions for reproducible builds.
GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
ZIG_VERSION="0.15.2"
ARM64_HOMEBREW_PREFIX="/opt/homebrew"
HOMEBREW_ZIG_BIN="$ARM64_HOMEBREW_PREFIX/opt/zig@0.15/bin/zig"
GHOSTTY_ARCH_DIAGNOSTICS="${GHOSTTY_ARCH_DIAGNOSTICS:-1}"
# The app's minimum macOS (Package.swift `.macOS(.v14)`). Objects built for a
# newer minimum, or for another platform entirely, cannot link into the app.
MACOS_DEPLOYMENT_TARGET="14.0"

GHOSTTY_REPO_URL="https://github.com/ghostty-org/ghostty.git"
CACHE_DIR="${GHOSTTY_CACHE_DIR:-$HOME/.cache/workspacemanager}"
ZIG_CACHE_DIR="${GHOSTTY_ZIG_CACHE_DIR:-$CACHE_DIR/zig-cache/$GHOSTTY_COMMIT}"
AUTO_CLONE_DIR="$CACHE_DIR/ghostty"
EXPLICIT_GHOSTTY_DIR="${GHOSTTY_DIR:-}"
EXPLICIT_ZIG_BIN="${GHOSTTY_ZIG_BIN:-}"
GHOSTTY_DIR=""
ZIG_RUNNER=()

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      die "$cmd is required ($hint)"
    fi
    die "$cmd is required"
  fi
}

# Ghostty's build.zig resolves "-Dxcframework-target=native" via the zig
# compiler binary's own baked-in build architecture, not the actual runtime
# host CPU. A zig binary that doesn't match `uname -m` (e.g. a
# Rosetta-translated x86_64 build on an arm64 host) silently produces a
# GhosttyKit slice for the wrong architecture instead of failing here — it
# surfaces later as "no such module 'GhosttyKit'" at Swift compile time.
zig_binary_matches_host_arch() {
  local zig_bin="$1"
  file "$zig_bin" 2>/dev/null | grep -q "$(uname -m)"
}

# Confirmed on an Xcode Cloud macOS image: its only available zig@0.15 bottle
# was Rosetta-translated x86_64 even though the host (and its own `uname -m`)
# is arm64. Neither replacement compiler works there: upstream ziglang.org's
# arm64 build fails to link its own build runner against this repo's supported
# Xcode SDKs ("undefined symbol: __availability_version_check" plus missing
# libSystem symbols; only Homebrew's zig@0.15 formula carries the needed
# Darwin linker patch), and bootstrapping a native /opt/homebrew needs sudo
# the Xcode Cloud user does not have (confirmed via build 574's log). So a
# wrong-arch Homebrew zig is accepted and asked to CROSS-COMPILE the host-arch
# slice: Ghostty's native xcframework slice hardcodes the zig compiler
# binary's own arch (`Config.genericMacOSTarget(b, null)`), so the pinned
# checkout gets a one-token patch replacing that `null` with the real host
# arch. zig is a native cross-compiler; the compiler binary's arch stops
# mattering once the slice target is explicit.
NEEDS_SLICE_ARCH_PATCH=0
SLICE_ARCH_PATCH_FILE="src/build/GhosttyXCFramework.zig"

host_zig_cpu_arch() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "aarch64" ;;
    x86_64) echo "x86_64" ;;
    *) die "unsupported host architecture for GhosttyKit: $(uname -m)" ;;
  esac
}

prepare_slice_arch_patch() {
  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    if [[ "$NEEDS_SLICE_ARCH_PATCH" == "1" ]]; then
      die "resolved zig does not match host arch and GHOSTTY_DIR is set; refusing to patch a user-managed checkout. Provide a host-arch zig via GHOSTTY_ZIG_BIN or unset GHOSTTY_DIR."
    fi

    # A user-managed checkout is never mutated, so a leftover slice-arch patch
    # (e.g. GHOSTTY_DIR pointing at this script's own cache dir after a killed
    # patched run) must fail loudly instead of silently retargeting the slice.
    if [[ -n "$(git -C "$GHOSTTY_DIR" status --porcelain -- "$SLICE_ARCH_PATCH_FILE")" ]]; then
      die "GHOSTTY_DIR has local modifications to $SLICE_ARCH_PATCH_FILE; reset it (git -C \"$GHOSTTY_DIR\" checkout -- $SLICE_ARCH_PATCH_FILE) or unset GHOSTTY_DIR"
    fi
    return
  fi

  # Reset unconditionally so a patch from a previous run never leaks into an
  # arch-matched build via the cached checkout.
  git -C "$GHOSTTY_DIR" checkout -- "$SLICE_ARCH_PATCH_FILE"

  if [[ "$NEEDS_SLICE_ARCH_PATCH" != "1" ]]; then
    return
  fi

  local arch
  arch="$(host_zig_cpu_arch)"
  local patch_path="$GHOSTTY_DIR/$SLICE_ARCH_PATCH_FILE"

  if ! grep -q 'Config\.genericMacOSTarget(b, null)' "$patch_path"; then
    die "expected 'Config.genericMacOSTarget(b, null)' in $SLICE_ARCH_PATCH_FILE at pinned commit $GHOSTTY_COMMIT; the pin changed — re-verify the slice-arch patch"
  fi

  sed -i '' "s/Config\.genericMacOSTarget(b, null)/Config.genericMacOSTarget(b, .$arch)/" "$patch_path"

  if ! grep -q "Config\.genericMacOSTarget(b, \.$arch)" "$patch_path"; then
    die "failed to patch $SLICE_ARCH_PATCH_FILE for host arch .$arch"
  fi

  echo "warning: resolved zig does not match host arch ($(uname -m)); patched $SLICE_ARCH_PATCH_FILE to cross-compile the native slice for .$arch" >&2
}

resolve_zig_runner() {
  if [[ -n "$EXPLICIT_ZIG_BIN" ]]; then
    if [[ ! -x "$EXPLICIT_ZIG_BIN" ]]; then
      die "GHOSTTY_ZIG_BIN is set but is not executable: $EXPLICIT_ZIG_BIN"
    fi

    if ! zig_binary_matches_host_arch "$EXPLICIT_ZIG_BIN"; then
      NEEDS_SLICE_ARCH_PATCH=1
    fi
    ZIG_RUNNER=("$EXPLICIT_ZIG_BIN")
    return
  fi

  if [[ -x "$HOMEBREW_ZIG_BIN" ]] && zig_binary_matches_host_arch "$HOMEBREW_ZIG_BIN"; then
    ZIG_RUNNER=("$HOMEBREW_ZIG_BIN")
    return
  fi

  # Some Xcode Cloud macOS images run Homebrew from /usr/local instead of the
  # standard Apple Silicon /opt/homebrew prefix. Only used as a fallback here
  # so a host with a real /opt/homebrew zig@0.15 (checked above) never gets
  # overridden by a different-prefix (and potentially different-arch) one.
  # A wrong-arch brew zig is still usable — it cross-compiles the host-arch
  # slice via the pinned-source patch (see prepare_slice_arch_patch).
  if command -v brew >/dev/null 2>&1; then
    local brew_zig_prefix
    brew_zig_prefix="$(brew --prefix zig@0.15 2>/dev/null || true)"
    if [[ -n "$brew_zig_prefix" && -x "$brew_zig_prefix/bin/zig" ]]; then
      if ! zig_binary_matches_host_arch "$brew_zig_prefix/bin/zig"; then
        NEEDS_SLICE_ARCH_PATCH=1
      fi
      ZIG_RUNNER=("$brew_zig_prefix/bin/zig")
      return
    fi
  fi

  if command -v mise >/dev/null 2>&1; then
    ZIG_RUNNER=(
      env
      "MISE_CONFIG_FILE=$PROJECT_DIR/.mise.toml"
      "MISE_CONFIG_ROOT=$PROJECT_DIR"
      "MISE_IGNORED_CONFIG_PATHS=$HOME/.config/mise${MISE_IGNORED_CONFIG_PATHS:+:$MISE_IGNORED_CONFIG_PATHS}"
      MISE_PARANOID=1
      mise exec --locked "zig@$ZIG_VERSION" -- zig
    )
    return
  fi

  require_cmd mise "https://mise.jdx.dev/"
}

require_msgfmt() {
  if command -v msgfmt >/dev/null 2>&1; then
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    local gettext_prefix
    gettext_prefix="$(brew --prefix gettext 2>/dev/null || true)"
    if [[ -x "$gettext_prefix/bin/msgfmt" ]]; then
      export PATH="$gettext_prefix/bin:$PATH"
      return
    fi
  fi

  die "msgfmt is required to build Ghostty translations (install Homebrew gettext; if it is keg-only, add \$(brew --prefix gettext)/bin to PATH)"
}

rewrite_modulemap() {
  local modulemap_path="$1"

  {
    echo "// This makes Ghostty available to the XCode build for the macOS app."
    echo "// We append \"Kit\" to it not to be cute, but because targets have to have"
    echo "// unique names and we use Ghostty for other things."
    echo "module GhosttyKit {"
    echo "    header \"ghostty.h\""
    echo "    export *"
    echo "}"
  } > "$modulemap_path"
}

archive_exports_ghostty_api() {
  local archive="$1"
  nm -gU "$archive" 2>/dev/null | grep ' _ghostty_init$' >/dev/null
}

# Prints "<platform> <minos>" for a Mach-O object — "macos 13.0",
# "other 17.0", or "none -" when it carries no version load command
# (platform-agnostic, e.g. raw assembly). otool prints LC_BUILD_VERSION
# platforms numerically (1 = macOS) or symbolically depending on version;
# older objects use LC_VERSION_MIN_MACOSX (or _IPHONEOS/_TVOS/_WATCHOS)
# instead. All version commands are scanned: a zippered object (macOS +
# Catalyst) counts as macOS with the macOS command's minos, whichever order
# the commands appear in. otool failing on a member must not kill the build
# under pipefail, hence the `|| true`.
object_platform_minos() {
  local object="$1"
  { otool -l "$object" 2>/dev/null || true; } | awk '
    $1 == "cmd" { curcmd = $2 }
    curcmd == "LC_BUILD_VERSION" && $1 == "platform" { platform = $2; seen = 1 }
    curcmd == "LC_BUILD_VERSION" && $1 == "minos" {
      if (platform == "1" || platform == "MACOS") mac_minos = $2
      else if (other == "") other = $2
    }
    curcmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { mac_minos = $2; seen = 1 }
    curcmd ~ /^LC_VERSION_MIN_/ && curcmd != "LC_VERSION_MIN_MACOSX" { seen = 1; if ($1 == "version" && other == "") other = $2 }
    END {
      if (mac_minos != "") print "macos " mac_minos
      else if (seen) print "other " (other == "" ? "-" : other)
      else print "none -"
    }
  '
}

# True when dotted-decimal version $1 <= $2.
version_lte() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$2" ]]
}

find_ghostty_archives() {
  local cache_root="$ZIG_CACHE_DIR/local/o"
  local candidate

  [[ -d "$cache_root" ]] || return 1

  while IFS= read -r candidate; do
    printf '%s\n' "$candidate"
  done < <(find "$cache_root" -type f -name "*.a" -exec ls -1t {} + 2>/dev/null)
}

repair_ghostty_archive_if_needed() {
  local archive="$1"

  if archive_exports_ghostty_api "$archive"; then
    return
  fi

  local archives_file
  archives_file="$(mktemp "${TMPDIR:-/tmp}/workspaces-ghostty-archives.XXXXXX")"
  if ! find_ghostty_archives > "$archives_file" || [[ ! -s "$archives_file" ]]; then
    rm -f "$archives_file"
    die "GhosttyKit archive does not export ghostty_init and no Zig cache archives were found"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-ghostty-archive.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN

  local index=0
  local source_archive
  while IFS= read -r source_archive; do
    # Fat archives (lipo products, e.g. from a universal-mode build sharing
    # this cache) are not ar-extractable; only thin archives carry objects.
    if lipo -info "$source_archive" 2>/dev/null | grep -q '^Architectures in the fat file'; then
      continue
    fi
    local archive_dir="$tmp_dir/objects/$index"
    mkdir -p "$archive_dir"
    (
      cd "$archive_dir"
      ar -x "$source_archive"
    )
    index=$((index + 1))
  done < "$archives_file"
  rm -f "$archives_file"

  chmod -R u+rwX "$tmp_dir"

  # The zig cache also holds build-time helper objects compiled for the
  # compiler host's own arch (e.g. x86_64 on a Rosetta-translated zig running
  # on an arm64 host), not just the target slice — sweeping every *.o
  # unfiltered produces a needlessly fat archive (both arches present, though
  # harmless since the linker only pulls the matching slice). Keep only
  # objects matching the host arch: `file -b` drops the path prefix (an
  # unanchored match against the full `file` line, path included, could keep
  # or drop an object based on its filename rather than its actual
  # architecture), and `-w` requires a whole-word match so "arm64" doesn't
  # also match "arm64e".
  #
  # Arch alone is not enough: a universal/iOS xcframework build sharing this
  # cache leaves thin arm64 archives for other platforms (iOS-simulator
  # objects are a fatal ld error when linking the macOS app) and macOS
  # objects with the host's own minimum version (unlinkable at the app's
  # deployment target). Drop those too; platform-agnostic objects with no
  # version load command are kept.
  local host_arch object platform_minos
  local drops_file="$tmp_dir/dropped-names"
  host_arch="$(uname -m)"
  : > "$drops_file"
  while IFS= read -r object; do
    if ! file -b "$object" 2>/dev/null | grep -qw "$host_arch"; then
      rm -f "$object"
      continue
    fi
    platform_minos="$(object_platform_minos "$object")"
    case "$platform_minos" in
      "none -") ;;
      macos\ *)
        if ! version_lte "${platform_minos#macos }" "$MACOS_DEPLOYMENT_TARGET"; then
          basename "$object" >> "$drops_file"
          rm -f "$object"
        fi
        ;;
      *)
        basename "$object" >> "$drops_file"
        rm -f "$object"
        ;;
    esac
  done < <(find "$tmp_dir/objects" -type f -name "*.o")

  # A platform/minos drop is only safe while another copy of that object
  # survives (the native build that just populated the cache provides one).
  # If the sweep removed every copy of a member, the archive would silently
  # lose symbols and fail at app link time — die here instead.
  local dropped_name
  while IFS= read -r dropped_name; do
    if ! find "$tmp_dir/objects" -type f -name "$dropped_name" -print -quit | grep -q .; then
      die "repair sweep dropped every copy of $dropped_name (wrong platform or minimum macOS above $MACOS_DEPLOYMENT_TARGET); the Zig cache has no usable copy. Purge and rebuild: ./scripts/build-ghosttykit.sh --purge-cache"
    fi
  done < <(sort -u "$drops_file")
  rm -f "$drops_file"

  if ! find "$tmp_dir/objects" -type f -name "*.o" -print -quit | grep -q .; then
    die "no $host_arch objects found in the Zig cache to repair the GhosttyKit archive"
  fi

  find "$tmp_dir/objects" -type f -name "*.o" -print0 \
    | xargs -0 libtool -static -o "$tmp_dir/libghostty-fat.a"
  mv "$tmp_dir/libghostty-fat.a" "$archive"
  rm -rf "$tmp_dir"
  trap - RETURN

  if ! archive_exports_ghostty_api "$archive"; then
    die "repaired GhosttyKit archive still does not export ghostty_init"
  fi
}

postprocess_xcframework() {
  local framework_dir="$1"

  while IFS= read -r modulemap; do
    rewrite_modulemap "$modulemap"
  done < <(find "$framework_dir" -type f -name module.modulemap)

  while IFS= read -r archive; do
    repair_ghostty_archive_if_needed "$archive"
    xcrun strip -S -x "$archive"
  done < <(find "$framework_dir" -type f -name "libghostty-fat.a")
}

# The failure mode this whole arch dance guards against is a silently
# wrong-arch slice that only surfaces later as "no such module 'GhosttyKit'"
# at Swift compile time. Fail here, loudly, instead.
assert_host_arch_slice() {
  local framework_dir="$1"
  local host_arch
  host_arch="$(uname -m)"

  local archive found=0
  while IFS= read -r archive; do
    found=1
    if ! lipo -info "$archive" 2>/dev/null | grep -q "$host_arch"; then
      die "built GhosttyKit slice does not contain host arch $host_arch: $(lipo -info "$archive" 2>&1)"
    fi
  done < <(find "$framework_dir" -type f -name "libghostty-fat.a" 2>/dev/null)

  if [[ "$found" == "0" ]]; then
    die "no libghostty-fat.a found in $framework_dir to verify architecture"
  fi

  # SwiftPM selects the slice from Info.plist metadata, not the archive, so a
  # repaired archive with the right objects can still hide a wrong-arch slice
  # declaration. The exact-quoted match ("arm64") does not false-positive on
  # LibraryIdentifier values like "macos-arm64".
  local info_plist="$framework_dir/Info.plist"
  if ! plutil -p "$info_plist" 2>/dev/null | grep -q "\"$host_arch\""; then
    die "xcframework Info.plist does not declare a slice supporting host arch $host_arch: $info_plist"
  fi
}

# A poisoned Zig cache can hand the repair sweep objects for the wrong
# platform or a newer minimum macOS than the app's deployment target. ld
# rejects wrong-platform objects outright — and CI swallowed exactly that
# error once (the v0.23.0 release: an iOS-simulator targets.o swept in from a
# universal build sharing the cache). Fail here, at GhosttyKit build time,
# with the remedy in hand.
assert_macos_deployment_target() {
  local framework_dir="$1"

  local archive violations
  while IFS= read -r archive; do
    violations="$({ otool -l "$archive" 2>/dev/null || true; } | awk -v max="$MACOS_DEPLOYMENT_TARGET" '
      function vgt(a, b,   n, m, i, x, y, av, bv) {
        n = split(a, av, "."); m = split(b, bv, ".")
        for (i = 1; i <= (n > m ? n : m); i++) {
          x = (i <= n) ? av[i] + 0 : 0
          y = (i <= m) ? bv[i] + 0 : 0
          if (x != y) return x > y
        }
        return 0
      }
      function flush() {
        if (member == "") return
        if (mac_minos != "") {
          if (vgt(mac_minos, max))
            printf "  %s: minimum macOS %s > %s\n", member, mac_minos, max
        } else if (seen)
          printf "  %s: platform %s (not macOS)\n", member, (plat_desc == "" ? "unknown" : plat_desc)
      }
      /^[^ \t].*\):$/ { flush(); member = $0; sub(/:$/, "", member); mac_minos = ""; seen = 0; plat_desc = ""; platform = ""; curcmd = "" }
      $1 == "cmd" { curcmd = $2 }
      curcmd == "LC_BUILD_VERSION" && $1 == "platform" {
        platform = $2; seen = 1
        if (platform != "1" && platform != "MACOS" && plat_desc == "") plat_desc = platform
      }
      curcmd == "LC_BUILD_VERSION" && $1 == "minos" {
        if (platform == "1" || platform == "MACOS") mac_minos = $2
      }
      curcmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { mac_minos = $2; seen = 1 }
      curcmd ~ /^LC_VERSION_MIN_/ && curcmd != "LC_VERSION_MIN_MACOSX" {
        seen = 1
        if (plat_desc == "") plat_desc = curcmd
      }
      END { flush() }
    ')"
    if [[ -n "$violations" ]]; then
      die "GhosttyKit archive has objects unusable at the app deployment target (macOS $MACOS_DEPLOYMENT_TARGET):
$violations
The shared Zig cache is likely polluted by a build for another platform or
macOS version (e.g. a universal/iOS xcframework build). Purge and rebuild:
  ./scripts/build-ghosttykit.sh --purge-cache"
    fi
  done < <(find "$framework_dir" -type f -name "libghostty-fat.a" 2>/dev/null)
}

log_arch_diagnostics() {
  local framework_dir="$1"

  if [[ "$GHOSTTY_ARCH_DIAGNOSTICS" != "1" ]]; then
    return
  fi

  echo "--- GhosttyKit architecture diagnostics (set GHOSTTY_ARCH_DIAGNOSTICS=0 to disable) ---"
  echo "host arch (uname -m): $(uname -m)"

  local zig_bin="${ZIG_RUNNER[0]}"
  if [[ -x "$zig_bin" ]]; then
    echo "zig runner binary: $zig_bin"
    file "$zig_bin" 2>&1 || true
  else
    echo "zig runner: ${ZIG_RUNNER[*]} (mise-wrapped invocation, not a direct binary path)"
  fi

  local info_plist="$framework_dir/Info.plist"
  if [[ -f "$info_plist" ]]; then
    echo "xcframework Info.plist ($info_plist):"
    plutil -p "$info_plist" 2>&1 || cat "$info_plist"
  fi

  local archive
  while IFS= read -r archive; do
    echo "xcframework archive: $archive"
    file "$archive" 2>&1 || true
    lipo -info "$archive" 2>&1 || true
  done < <(find "$framework_dir" -type f -name "libghostty-fat.a" 2>/dev/null)

  echo "--- end GhosttyKit architecture diagnostics ---"
}

resolve_ghostty_dir() {
  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    GHOSTTY_DIR="$EXPLICIT_GHOSTTY_DIR"
  else
    GHOSTTY_DIR="$AUTO_CLONE_DIR"
  fi
}

ensure_ghostty_checkout() {
  if [[ -d "$GHOSTTY_DIR/.git" ]]; then
    return
  fi

  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    die "GHOSTTY_DIR is set but is not a git checkout: $GHOSTTY_DIR"
  fi

  mkdir -p "$CACHE_DIR"
  rm -rf "$GHOSTTY_DIR"
  git clone "$GHOSTTY_REPO_URL" "$GHOSTTY_DIR"
}

ensure_pinned_commit() {
  local current_commit
  current_commit="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"

  if [[ -n "$EXPLICIT_GHOSTTY_DIR" ]]; then
    if [[ "$current_commit" != "$GHOSTTY_COMMIT" ]]; then
      die "GHOSTTY_DIR is not at pinned commit
  expected: $GHOSTTY_COMMIT
  actual:   $current_commit"
    fi
    return
  fi

  if [[ "$current_commit" != "$GHOSTTY_COMMIT" ]]; then
    # A slice-arch patch left behind by a killed run would make the detach
    # below refuse to overwrite local changes; drop it first (best-effort —
    # the file may not exist at the old commit).
    git -C "$GHOSTTY_DIR" checkout -- "$SLICE_ARCH_PATCH_FILE" 2>/dev/null || true
    # Ghostty's `tip` tag moves; force tag updates so it does not block pinned commits.
    git -C "$GHOSTTY_DIR" fetch --force --tags origin
    git -C "$GHOSTTY_DIR" checkout --detach "$GHOSTTY_COMMIT"
  fi
}

build_ghostty_xcframework() {
  (
    cd "$GHOSTTY_DIR"
    mkdir -p "$ZIG_CACHE_DIR/local" "$ZIG_CACHE_DIR/global"
    "${ZIG_RUNNER[@]}" build \
      --cache-dir "$ZIG_CACHE_DIR/local" \
      --global-cache-dir "$ZIG_CACHE_DIR/global" \
      -Demit-xcframework=true \
      -Demit-macos-app=false \
      -Dxcframework-target=native \
      -Doptimize=ReleaseFast
  )
}

find_xcframework_src() {
  local candidate
  local candidates=(
    "$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
    "$GHOSTTY_DIR/zig-out/macos/GhosttyKit.xcframework"
    "$GHOSTTY_DIR/zig-out/GhosttyKit.xcframework"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

install_xcframework() {
  local src="$1"
  mkdir -p "$OUT_DIR"
  rm -rf "$OUT_DIR/GhosttyKit.xcframework"
  cp -R "$src" "$OUT_DIR/"
}

main() {
  local arg purge_cache=0
  for arg in "$@"; do
    case "$arg" in
      --purge-cache) purge_cache=1 ;;
      *) die "unknown argument: $arg (supported: --purge-cache)" ;;
    esac
  done

  require_cmd git
  require_cmd xcrun
  require_msgfmt
  resolve_zig_runner

  if [[ "$purge_cache" == "1" ]]; then
    # Only ever delete the script-managed per-commit location. A user-managed
    # GHOSTTY_ZIG_CACHE_DIR could point anywhere; refuse rather than rm -rf it.
    if [[ -n "${GHOSTTY_ZIG_CACHE_DIR:-}" ]]; then
      die "--purge-cache refuses to delete a user-managed GHOSTTY_ZIG_CACHE_DIR; clean it yourself or unset it"
    fi
    echo "Purging Zig cache for pinned commit: $ZIG_CACHE_DIR"
    rm -rf "$ZIG_CACHE_DIR"
  fi

  resolve_ghostty_dir
  ensure_ghostty_checkout
  ensure_pinned_commit
  prepare_slice_arch_patch
  build_ghostty_xcframework

  local xcframework_src
  if ! xcframework_src="$(find_xcframework_src)"; then
    die "expected xcframework not found in known output locations"
  fi

  install_xcframework "$xcframework_src"
  postprocess_xcframework "$OUT_DIR/GhosttyKit.xcframework"
  log_arch_diagnostics "$OUT_DIR/GhosttyKit.xcframework"
  assert_host_arch_slice "$OUT_DIR/GhosttyKit.xcframework"
  assert_macos_deployment_target "$OUT_DIR/GhosttyKit.xcframework"
  echo "Built GhosttyKit.xcframework -> $OUT_DIR/GhosttyKit.xcframework"
}

main "$@"
