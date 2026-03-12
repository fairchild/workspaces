#!/bin/bash
# ============================================================================
# setup-release-secrets.sh - Configure GitHub release secrets from a verified p12
# ============================================================================
#
# This script configures required repository secrets/variables for release.yml.
#
# Secrets (sensitive):
#   - APPLE_DEVELOPER_ID_CERT_BASE64
#   - APPLE_DEVELOPER_ID_CERT_PASSWORD
#   - APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64
#   - APPLE_APP_PASSWORD
#
# Variables (non-sensitive):
#   - APPLE_ID
#   - APPLE_TEAM_ID
#
# Behavior:
#   - Idempotent by default: only sets values that are missing
#   - Use --force to overwrite existing secrets/variables
#
# Optional:
#   - Trigger and watch Release workflow on main after setup
#
# Usage (interactive):
#   ./scripts/setup-release-secrets.sh \
#     --p12-path ~/.config/apple/Developer_ID_Application_LKVN4J3C6C.p12 \
#     --profile-path ~/.config/apple/workspaces.provisionprofile
#
# Usage (non-interactive):
#   P12_PASSWORD='...' APPLE_ID='...' APPLE_APP_PASSWORD='...' \
#   ./scripts/setup-release-secrets.sh \
#     --p12-path ~/.config/apple/Developer_ID_Application_LKVN4J3C6C.p12 \
#     --profile-path ~/.config/apple/workspaces.provisionprofile \
#     --team-id LKVN4J3C6C \
#     --non-interactive \
#     --run-release \
#     --watch
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-p12.sh"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

DEFAULT_TEAM_ID="LKVN4J3C6C"
DEFAULT_P12_PATH="$HOME/.config/apple/Developer_ID_Application_LKVN4J3C6C.p12"
DEFAULT_PROFILE_PATH="$HOME/.config/apple/workspaces.provisionprofile"
EXPECTED_BUNDLE_ID="com.cloudcompute.workspaces"

P12_PATH="${P12:-$DEFAULT_P12_PATH}"
PROFILE_PATH="${PROVISIONING_PROFILE_PATH:-$DEFAULT_PROFILE_PATH}"
TEAM_ID="${APPLE_TEAM_ID:-$DEFAULT_TEAM_ID}"
APPLE_ID_VALUE="${APPLE_ID:-}"
APPLE_APP_PASSWORD_VALUE="${APPLE_APP_PASSWORD:-}"
P12_PASSWORD_VALUE="${P12_PASSWORD:-}"

NON_INTERACTIVE=false
RUN_RELEASE=false
WATCH_RELEASE=false
FORCE=false
RELEASE_REF="main"

usage() {
    cat <<'EOF'
setup-release-secrets.sh - Configure GitHub release secrets from a verified p12

Options:
  --p12-path PATH         Path to Developer ID Application .p12
  --profile-path PATH     Path to Developer ID provisioning profile
  --team-id TEAM          Apple Team ID (default: LKVN4J3C6C)
  --apple-id EMAIL        Apple ID for notarization
  --app-password PASS     App-specific password for notarization
  --p12-password PASS     Export password used to protect the .p12
  --non-interactive       Do not prompt; fail if required values are missing
  --force                 Overwrite existing secrets/variables
  --run-release           Trigger GitHub "Release" workflow after setting secrets
  --watch                 If --run-release is set, watch run until completion
  --ref BRANCH            Ref for workflow dispatch (default: main)
  --help                  Show this help

Env alternatives:
  P12, P12_PASSWORD, PROVISIONING_PROFILE_PATH, APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID

Defaults:
  p12 path: ~/.config/apple/Developer_ID_Application_LKVN4J3C6C.p12
  profile path: ~/.config/apple/workspaces.provisionprofile
EOF
}

log() {
    echo "[setup-release-secrets] $*"
}

fail() {
    echo "[setup-release-secrets] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

plist_print() {
    local plist_path="$1"
    local key_path="$2"
    "$PLIST_BUDDY" -c "Print :$key_path" "$plist_path" 2>/dev/null || true
}

plist_array_values() {
    local plist_path="$1"
    local key_path="$2"
    local index=0
    local value=""

    while value="$("$PLIST_BUDDY" -c "Print :$key_path:$index" "$plist_path" 2>/dev/null)"; do
        printf '%s\n' "$value"
        index=$((index + 1))
    done
}

pattern_matches_value() {
    local value="$1"
    local pattern="$2"

    if [[ "$pattern" == *"*" ]]; then
        local prefix="${pattern%\*}"
        [[ "$value" == "$prefix"* ]]
        return
    fi

    [[ "$value" == "$pattern" ]]
}

array_authorizes_value() {
    local expected="$1"
    shift

    local item=""
    for item in "$@"; do
        if pattern_matches_value "$expected" "$item"; then
            return 0
        fi
    done

    return 1
}

have_secret() {
    local name="$1"
    local names=""

    if names="$(gh secret list --json name --jq '.[].name' 2>/dev/null)"; then
        printf '%s\n' "$names" | grep -Fxq "$name"
        return
    fi

    # Fallback for older gh versions without JSON support.
    names="$(gh secret list 2>/dev/null | awk '{print $1}' || true)"
    printf '%s\n' "$names" | grep -Fxq "$name"
}

have_variable() {
    local name="$1"
    local names=""

    if names="$(gh variable list --json name --jq '.[].name' 2>/dev/null)"; then
        printf '%s\n' "$names" | grep -Fxq "$name"
        return
    fi

    # Fallback for older gh versions without JSON support.
    names="$(gh variable list 2>/dev/null | awk '{print $1}' || true)"
    printf '%s\n' "$names" | grep -Fxq "$name"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --p12-path)
            [[ $# -ge 2 ]] || fail "--p12-path requires a value"
            P12_PATH="$2"
            shift 2
            ;;
        --team-id)
            [[ $# -ge 2 ]] || fail "--team-id requires a value"
            TEAM_ID="$2"
            shift 2
            ;;
        --profile-path)
            [[ $# -ge 2 ]] || fail "--profile-path requires a value"
            PROFILE_PATH="$2"
            shift 2
            ;;
        --apple-id)
            [[ $# -ge 2 ]] || fail "--apple-id requires a value"
            APPLE_ID_VALUE="$2"
            shift 2
            ;;
        --app-password)
            [[ $# -ge 2 ]] || fail "--app-password requires a value"
            APPLE_APP_PASSWORD_VALUE="$2"
            shift 2
            ;;
        --p12-password)
            [[ $# -ge 2 ]] || fail "--p12-password requires a value"
            P12_PASSWORD_VALUE="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --run-release)
            RUN_RELEASE=true
            shift
            ;;
        --watch)
            WATCH_RELEASE=true
            shift
            ;;
        --ref)
            [[ $# -ge 2 ]] || fail "--ref requires a value"
            RELEASE_REF="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

require_cmd gh
require_cmd base64
require_cmd mktemp

[[ -x "$VERIFY_SCRIPT" ]] || fail "Missing verifier script at $VERIFY_SCRIPT"

log "Checking GitHub auth"
gh auth status >/dev/null

NEED_CERT_B64=false
NEED_CERT_PASSWORD=false
NEED_PROFILE_B64=false
NEED_APP_PASSWORD=false
NEED_APPLE_ID_VAR=false
NEED_TEAM_ID_VAR=false

if [[ "$FORCE" == true ]] || ! have_secret "APPLE_DEVELOPER_ID_CERT_BASE64"; then
    NEED_CERT_B64=true
fi
if [[ "$FORCE" == true ]] || ! have_secret "APPLE_DEVELOPER_ID_CERT_PASSWORD"; then
    NEED_CERT_PASSWORD=true
fi
if [[ "$FORCE" == true ]] || ! have_secret "APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64"; then
    NEED_PROFILE_B64=true
fi
if [[ "$FORCE" == true ]] || ! have_secret "APPLE_APP_PASSWORD"; then
    NEED_APP_PASSWORD=true
fi
if [[ "$FORCE" == true ]] || ! have_variable "APPLE_ID"; then
    NEED_APPLE_ID_VAR=true
fi
if [[ "$FORCE" == true ]] || ! have_variable "APPLE_TEAM_ID"; then
    NEED_TEAM_ID_VAR=true
fi

NEED_CERT_SETUP=false
if [[ "$NEED_CERT_B64" == true || "$NEED_CERT_PASSWORD" == true ]]; then
    NEED_CERT_SETUP=true
fi

if [[ "$NEED_CERT_SETUP" == true ]]; then
    [[ -n "$P12_PATH" ]] || fail "Missing p12 path. Use --p12-path or set P12=/path/to/file.p12."
    P12_PATH="${P12_PATH/#\~/$HOME}"
    P12_PATH="$(cd "$(dirname "$P12_PATH")" && pwd)/$(basename "$P12_PATH")"
    [[ -f "$P12_PATH" ]] || fail "p12 file not found: $P12_PATH (default is $DEFAULT_P12_PATH)"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -n "$P12_PASSWORD_VALUE" ]] || fail "P12_PASSWORD/--p12-password is required in non-interactive mode."
    elif [[ -z "$P12_PASSWORD_VALUE" ]]; then
        read -r -s -p "Enter p12 export password: " P12_PASSWORD_VALUE
        echo ""
    fi

    [[ -n "$TEAM_ID" ]] || fail "Team ID cannot be empty."
    [[ -n "$P12_PASSWORD_VALUE" ]] || fail "p12 password cannot be empty."

    log "Verifying p12 contents"
    P12="$P12_PATH" \
    P12_PASSWORD="$P12_PASSWORD_VALUE" \
    "$VERIFY_SCRIPT" --non-interactive --team-id "$TEAM_ID" >/dev/null
    log "p12 verification passed"
fi

if [[ "$NEED_PROFILE_B64" == true ]]; then
    require_cmd security
    [[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found at $PLIST_BUDDY"
    [[ -n "$PROFILE_PATH" ]] || fail "Missing provisioning profile path. Use --profile-path or set PROVISIONING_PROFILE_PATH=/path/to/profile.provisionprofile."
    PROFILE_PATH="${PROFILE_PATH/#\~/$HOME}"
    PROFILE_PATH="$(cd "$(dirname "$PROFILE_PATH")" && pwd)/$(basename "$PROFILE_PATH")"
    [[ -f "$PROFILE_PATH" ]] || fail "Provisioning profile not found: $PROFILE_PATH (default is $DEFAULT_PROFILE_PATH)"

    PROFILE_PLIST="$(mktemp)"
    if ! security cms -D -i "$PROFILE_PATH" >"$PROFILE_PLIST"; then
        rm -f "$PROFILE_PLIST"
        fail "Failed to decode provisioning profile: $PROFILE_PATH"
    fi

    PROFILE_PLATFORM="$(plist_print "$PROFILE_PLIST" "Platform:0")"
    [[ "$PROFILE_PLATFORM" == "OSX" ]] || fail "Provisioning profile platform must be OSX for macOS release builds (got ${PROFILE_PLATFORM:-<missing>})"

    PROFILE_APPLICATION_IDENTIFIER="$(plist_print "$PROFILE_PLIST" "Entitlements:application-identifier")"
    if [[ -z "$PROFILE_APPLICATION_IDENTIFIER" ]]; then
        PROFILE_APPLICATION_IDENTIFIER="$(plist_print "$PROFILE_PLIST" "Entitlements:com.apple.application-identifier")"
    fi
    [[ -n "$PROFILE_APPLICATION_IDENTIFIER" ]] || fail "Provisioning profile is missing application-identifier entitlement"

    PROFILE_PREFIX="${PROFILE_APPLICATION_IDENTIFIER%%.*}"
    [[ "$PROFILE_PREFIX" != "$PROFILE_APPLICATION_IDENTIFIER" ]] || fail "Provisioning profile application-identifier is malformed: $PROFILE_APPLICATION_IDENTIFIER"

    EXPECTED_APPLICATION_IDENTIFIER="$PROFILE_PREFIX.$EXPECTED_BUNDLE_ID"
    EXPECTED_KEYCHAIN_GROUP="$PROFILE_PREFIX.$EXPECTED_BUNDLE_ID"
    pattern_matches_value "$EXPECTED_APPLICATION_IDENTIFIER" "$PROFILE_APPLICATION_IDENTIFIER" \
        || fail "Provisioning profile does not authorize bundle identifier $EXPECTED_BUNDLE_ID"

    PROFILE_KEYCHAIN_GROUPS=()
    while IFS= read -r keychain_group; do
        PROFILE_KEYCHAIN_GROUPS+=("$keychain_group")
    done < <(plist_array_values "$PROFILE_PLIST" "Entitlements:keychain-access-groups")
    (( ${#PROFILE_KEYCHAIN_GROUPS[@]} > 0 )) || fail "Provisioning profile is missing keychain-access-groups"

    array_authorizes_value "$EXPECTED_KEYCHAIN_GROUP" "${PROFILE_KEYCHAIN_GROUPS[@]}" \
        || fail "Provisioning profile does not authorize keychain group $EXPECTED_KEYCHAIN_GROUP"

    rm -f "$PROFILE_PLIST"
fi

if [[ "$NEED_APPLE_ID_VAR" == true ]]; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -n "$APPLE_ID_VALUE" ]] || fail "APPLE_ID/--apple-id is required in non-interactive mode."
    elif [[ -z "$APPLE_ID_VALUE" ]]; then
        read -r -p "Enter Apple ID for notarization: " APPLE_ID_VALUE
    fi
    [[ -n "$APPLE_ID_VALUE" ]] || fail "Apple ID cannot be empty."
fi

if [[ "$NEED_APP_PASSWORD" == true ]]; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -n "$APPLE_APP_PASSWORD_VALUE" ]] || fail "APPLE_APP_PASSWORD/--app-password is required in non-interactive mode."
    elif [[ -z "$APPLE_APP_PASSWORD_VALUE" ]]; then
        read -r -s -p "Enter Apple app-specific password: " APPLE_APP_PASSWORD_VALUE
        echo ""
    fi
    [[ -n "$APPLE_APP_PASSWORD_VALUE" ]] || fail "Apple app-specific password cannot be empty."
fi

if [[ "$NEED_TEAM_ID_VAR" == true ]]; then
    [[ -n "$TEAM_ID" ]] || fail "Team ID cannot be empty."
fi

TMP_B64=""
TMP_PROFILE_B64=""
cleanup() {
    if [[ -n "$TMP_B64" ]]; then
        rm -f "$TMP_B64"
    fi
    if [[ -n "$TMP_PROFILE_B64" ]]; then
        rm -f "$TMP_PROFILE_B64"
    fi
}
trap cleanup EXIT

if [[ "$NEED_CERT_B64" == true ]]; then
    TMP_B64="$(mktemp)"
    if base64 -i "$P12_PATH" >/dev/null 2>&1; then
        base64 -i "$P12_PATH" > "$TMP_B64"
    else
        base64 "$P12_PATH" > "$TMP_B64"
    fi
fi

if [[ "$NEED_PROFILE_B64" == true ]]; then
    TMP_PROFILE_B64="$(mktemp)"
    if base64 -i "$PROFILE_PATH" >/dev/null 2>&1; then
        base64 -i "$PROFILE_PATH" > "$TMP_PROFILE_B64"
    else
        base64 "$PROFILE_PATH" > "$TMP_PROFILE_B64"
    fi
fi

log "Applying GitHub configuration (idempotent mode: force=$FORCE)"

if [[ "$NEED_CERT_B64" == true ]]; then
    gh secret set APPLE_DEVELOPER_ID_CERT_BASE64 < "$TMP_B64"
    log "Set secret APPLE_DEVELOPER_ID_CERT_BASE64"
else
    log "Skip secret APPLE_DEVELOPER_ID_CERT_BASE64 (already set)"
fi

if [[ "$NEED_CERT_PASSWORD" == true ]]; then
    gh secret set APPLE_DEVELOPER_ID_CERT_PASSWORD -b "$P12_PASSWORD_VALUE"
    log "Set secret APPLE_DEVELOPER_ID_CERT_PASSWORD"
else
    log "Skip secret APPLE_DEVELOPER_ID_CERT_PASSWORD (already set)"
fi

if [[ "$NEED_PROFILE_B64" == true ]]; then
    gh secret set APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64 < "$TMP_PROFILE_B64"
    log "Set secret APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64"
else
    log "Skip secret APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64 (already set)"
fi

if [[ "$NEED_APP_PASSWORD" == true ]]; then
    gh secret set APPLE_APP_PASSWORD -b "$APPLE_APP_PASSWORD_VALUE"
    log "Set secret APPLE_APP_PASSWORD"
else
    log "Skip secret APPLE_APP_PASSWORD (already set)"
fi

if [[ "$NEED_APPLE_ID_VAR" == true ]]; then
    gh variable set APPLE_ID -b "$APPLE_ID_VALUE"
    log "Set variable APPLE_ID"
else
    log "Skip variable APPLE_ID (already set)"
fi

if [[ "$NEED_TEAM_ID_VAR" == true ]]; then
    gh variable set APPLE_TEAM_ID -b "$TEAM_ID"
    log "Set variable APPLE_TEAM_ID"
else
    log "Skip variable APPLE_TEAM_ID (already set)"
fi

log "Configured APPLE_* secrets:"
gh secret list | grep -E '^APPLE_' || true
log "Configured APPLE_* variables:"
gh variable list | grep -E '^APPLE_' || true

if [[ "$RUN_RELEASE" == true ]]; then
    log "Triggering Release workflow on ref '$RELEASE_REF'"
    gh workflow run Release --ref "$RELEASE_REF"

    if [[ "$WATCH_RELEASE" == true ]]; then
        log "Resolving latest Release run id"
        RUN_ID="$(
            gh run list --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId'
        )"
        [[ -n "$RUN_ID" ]] || fail "Could not resolve Release run id."

        log "Watching run $RUN_ID"
        gh run watch "$RUN_ID" --exit-status
    else
        log "Release workflow triggered. Use: gh run list --workflow Release --limit 1"
    fi
fi

log "Done"
