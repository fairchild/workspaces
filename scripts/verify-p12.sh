#!/bin/bash
# ============================================================================
# verify-p12.sh - Verify exported Apple signing .p12 for release automation
# ============================================================================
#
# Usage:
#   ./scripts/verify-p12.sh --path /absolute/path/to/cert.p12
#   P12=/absolute/path/to/cert.p12 ./scripts/verify-p12.sh
#   P12=/absolute/path/to/cert.p12 P12_PASSWORD='...' ./scripts/verify-p12.sh --non-interactive
#
# Optional:
#   --team-id LKVN4J3C6C     Expected Apple Team ID (default: LKVN4J3C6C)
#   --password-env NAME      Env var name for password (default: P12_PASSWORD)
#   --non-interactive        Fail instead of prompting for password
#   --help                   Show this help
#
# Exits non-zero if:
#   - file is unreadable
#   - password is wrong
#   - certificate subject is not Developer ID Application
#   - certificate subject does not contain expected Team ID
#   - private key is missing from the .p12
#
# ============================================================================

set -euo pipefail

EXPECTED_TEAM_ID="LKVN4J3C6C"
DEFAULT_P12_PATH="$HOME/.config/apple/Developer_ID_Application_LKVN4J3C6C.p12"
PASSWORD_ENV_NAME="P12_PASSWORD"
NON_INTERACTIVE=false
P12_PATH="${P12:-$DEFAULT_P12_PATH}"

usage() {
  cat <<'EOF'
verify-p12.sh - Verify exported Apple signing .p12 for release automation

Usage:
  ./scripts/verify-p12.sh --path /absolute/path/to/cert.p12
  P12=/absolute/path/to/cert.p12 ./scripts/verify-p12.sh
  P12=/absolute/path/to/cert.p12 P12_PASSWORD='...' ./scripts/verify-p12.sh --non-interactive

Optional:
  --team-id LKVN4J3C6C     Expected Apple Team ID (default: LKVN4J3C6C)
  --password-env NAME      Env var name for password (default: P12_PASSWORD)
  --non-interactive        Fail instead of prompting for password
  --help                   Show this help

Default path:
  ~/.config/apple/Developer_ID_Application_LKVN4J3C6C.p12
EOF
}

log() {
  echo "[verify-p12] $*"
}

fail() {
  echo "[verify-p12] ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      [[ $# -ge 2 ]] || fail "--path requires a value"
      P12_PATH="$2"
      shift 2
      ;;
    --team-id)
      [[ $# -ge 2 ]] || fail "--team-id requires a value"
      EXPECTED_TEAM_ID="$2"
      shift 2
      ;;
    --password-env)
      [[ $# -ge 2 ]] || fail "--password-env requires a value"
      PASSWORD_ENV_NAME="$2"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
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

P12_PATH="${P12_PATH/#\~/$HOME}"
[[ -f "$P12_PATH" ]] || fail "File not found: $P12_PATH"
[[ -r "$P12_PATH" ]] || fail "File is not readable: $P12_PATH"

command -v openssl >/dev/null 2>&1 || fail "openssl is required but not found in PATH."

PASSWORD="${!PASSWORD_ENV_NAME:-}"

if [[ -z "$PASSWORD" ]]; then
  if [[ "$NON_INTERACTIVE" == true ]]; then
    fail "Password env '$PASSWORD_ENV_NAME' is not set (non-interactive mode)."
  fi

  read -r -s -p "Enter password for $(basename "$P12_PATH"): " PASSWORD
  echo ""
  [[ -n "$PASSWORD" ]] || fail "Password cannot be empty."
fi

PASSIN=("pass:$PASSWORD")

log "Step 1/3: validating p12 and password"
if ! openssl pkcs12 -in "$P12_PATH" -info -noout -passin "${PASSIN[0]}" >/dev/null 2>&1; then
  fail "Unable to read p12. Check password and file integrity."
fi
log "PASS: p12 file/password are valid"

log "Step 2/3: reading certificate identity"
CERT_INFO="$(openssl pkcs12 -in "$P12_PATH" -clcerts -nokeys -passin "${PASSIN[0]}" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate)"
SUBJECT_LINE="$(printf '%s\n' "$CERT_INFO" | awk '/^subject=/{print; exit}')"
ISSUER_LINE="$(printf '%s\n' "$CERT_INFO" | awk '/^issuer=/{print; exit}')"
ENDDATE_LINE="$(printf '%s\n' "$CERT_INFO" | awk '/^notAfter=/{print; exit}')"

[[ -n "$SUBJECT_LINE" ]] || fail "Could not parse subject from p12."
[[ "$SUBJECT_LINE" == *"Developer ID Application"* ]] || fail "Subject is not Developer ID Application: $SUBJECT_LINE"
[[ "$SUBJECT_LINE" == *"($EXPECTED_TEAM_ID)"* ]] || fail "Subject team ID does not match expected '$EXPECTED_TEAM_ID': $SUBJECT_LINE"

log "PASS: certificate subject is Developer ID Application for team $EXPECTED_TEAM_ID"
echo "$SUBJECT_LINE"
[[ -n "$ISSUER_LINE" ]] && echo "$ISSUER_LINE"
[[ -n "$ENDDATE_LINE" ]] && echo "$ENDDATE_LINE"

log "Step 3/3: verifying private key is included"
KEY_MATERIAL="$(openssl pkcs12 -in "$P12_PATH" -nocerts -nodes -passin "${PASSIN[0]}" 2>/dev/null || true)"
if ! printf '%s\n' "$KEY_MATERIAL" | grep -Eq "BEGIN (ENCRYPTED )?PRIVATE KEY"; then
  fail "No private key found in p12. Re-export from Keychain using 'My Certificates'."
fi
log "PASS: private key is present"

log "SUCCESS: p12 verification completed"
