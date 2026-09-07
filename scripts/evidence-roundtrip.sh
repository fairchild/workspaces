#!/usr/bin/env bash
# ==========================================================================
# evidence-roundtrip.sh — prove the evidence store's access rules end to end
# ==========================================================================
#
# Exercises the four properties the store is supposed to have: only a holder of
# EVIDENCE_UPLOAD_TOKEN can write, anyone can read, only a holder of the token
# can withdraw, and an object is really gone once withdrawn. Uploads one small
# text file, deletes it again, and leaves nothing behind.
#
# Usage:
#   ./scripts/evidence-roundtrip.sh                                   # production
#   ./scripts/evidence-roundtrip.sh --base-url http://127.0.0.1:8799  # wrangler dev
#
# Requires EVIDENCE_UPLOAD_TOKEN in the environment (same resolution as
# scripts/evidence.sh: repo-root .env). The token is never printed.
# ==========================================================================

set -uo pipefail

BASE_URL="${EVIDENCE_BASE_URL:-https://evidence.cloudcompute.com}"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--base-url)
		BASE_URL="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,18p' "$0"
		exit 0
		;;
	*)
		echo "error: unknown option: $1" >&2
		exit 1
		;;
	esac
done
BASE_URL="${BASE_URL%/}"

if [[ -z "${EVIDENCE_UPLOAD_TOKEN:-}" ]]; then
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	if [[ -f "$REPO_ROOT/.env" ]]; then
		set -a
		# shellcheck disable=SC1091
		source "$REPO_ROOT/.env"
		set +a
	fi
fi
if [[ -z "${EVIDENCE_UPLOAD_TOKEN:-}" ]]; then
	echo "error: EVIDENCE_UPLOAD_TOKEN is not set (see scripts/evidence.sh)" >&2
	exit 2
fi

FAILURES=0
check() {
	local label="$1" expected="$2" actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		printf '  ok    %-46s %s\n' "$label" "$actual"
	else
		printf '  FAIL  %-46s %s (expected %s)\n' "$label" "$actual" "$expected"
		FAILURES=$((FAILURES + 1))
	fi
}

BODY="$(mktemp -t evidence-roundtrip)"
trap 'rm -f "$BODY"' EXIT
printf 'evidence-store round trip, %s. Harmless; deleted by this script.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$BODY"

REQUESTED="workspaces/roundtrip/$(date -u +%Y%m%d-%H%M%S)-roundtrip.txt"

echo "evidence store round trip against $BASE_URL"
echo
echo "unauthenticated callers are refused:"
check "PUT without a token" 401 "$(curl -s -o /dev/null -w '%{http_code}' \
	-X PUT --data-binary @"$BODY" -H 'Content-Type: text/plain' "$BASE_URL/$REQUESTED")"
check "PUT with a wrong token" 401 "$(curl -s -o /dev/null -w '%{http_code}' \
	-X PUT -H 'Authorization: Bearer not-the-token' --data-binary @"$BODY" \
	-H 'Content-Type: text/plain' "$BASE_URL/$REQUESTED")"
check "DELETE without a token" 401 "$(curl -s -o /dev/null -w '%{http_code}' \
	-X DELETE "$BASE_URL/$REQUESTED")"
check "DELETE with a wrong token" 401 "$(curl -s -o /dev/null -w '%{http_code}' \
	-X DELETE -H 'Authorization: Bearer not-the-token' "$BASE_URL/$REQUESTED")"

echo
echo "the token holder can upload:"
PUT_BODY="$(curl -s -X PUT -H "Authorization: Bearer $EVIDENCE_UPLOAD_TOKEN" \
	-H 'Content-Type: text/plain' --data-binary @"$BODY" "$BASE_URL/$REQUESTED")"
# Address the object by the returned key rather than the returned url: the
# worker builds that url from its routed hostname, which under `wrangler dev`
# is still the production custom domain.
STORED_KEY="$(printf '%s' "$PUT_BODY" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')"
if [[ -z "$STORED_KEY" ]]; then
	echo "  FAIL  PUT returned no key: $PUT_BODY"
	exit 1
fi
STORED_URL="$BASE_URL/$STORED_KEY"
check "PUT mints a key, not the requested path" "different" \
	"$([[ "$STORED_KEY" != "$REQUESTED" ]] && echo different || echo same)"
printf '  info  stored at %s\n' "$STORED_KEY"

echo
echo "the requested path is not where it landed:"
check "GET the path we asked for" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$REQUESTED")"

echo
echo "anyone can read the minted URL:"
check "GET the minted URL, no token" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$STORED_URL")"
check "GET returns the bytes we uploaded" "same" \
	"$([[ "$(curl -s "$STORED_URL")" == "$(cat "$BODY")" ]] && echo same || echo different)"

echo
echo "only the token holder can withdraw it:"
check "DELETE the minted URL without a token" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$STORED_URL")"
check "it is still there afterwards" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$STORED_URL")"
check "DELETE with the token" 204 "$(curl -s -o /dev/null -w '%{http_code}' \
	-X DELETE -H "Authorization: Bearer $EVIDENCE_UPLOAD_TOKEN" "$STORED_URL")"
check "GET after the withdrawal" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$STORED_URL")"

echo
echo "oversize uploads are refused:"
# Cloudflare presents a Content-Length to the worker even when the client
# streams without one, so production answers 413. Miniflare passes the missing
# header through, so `wrangler dev` answers 411. Either is a refusal.
OVERSIZE="$(head -c 53477376 /dev/zero | curl -s -o /dev/null -w '%{http_code}' \
	-X PUT -H "Authorization: Bearer $EVIDENCE_UPLOAD_TOKEN" \
	-H 'Content-Type: text/plain' -T - "$BASE_URL/workspaces/roundtrip/oversize.txt")"
check "PUT 51 MiB, length undeclared by the client" "refused" \
	"$([[ "$OVERSIZE" == "413" || "$OVERSIZE" == "411" ]] && echo refused || echo "$OVERSIZE")"
check "the oversize object did not land" 404 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/workspaces/roundtrip/oversize.txt")"

echo
if [[ "$FAILURES" -eq 0 ]]; then
	echo "all checks passed; nothing left in the store"
else
	echo "$FAILURES check(s) failed"
fi
exit "$FAILURES"
