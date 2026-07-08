#!/usr/bin/env bash
# ==========================================================================
# upload-evidence.sh — batch-upload a web-next evidence walk to the R2 store
# ==========================================================================
#
# `pnpm run evidence` writes a light+dark screenshot walk to output/evidence/
# (gitignored) but doesn't upload it — the repo's evidence gate requires
# uploaded URLs in the PR body, not local-only files (docs/development/
# evidence.md). This wraps the repo-root scripts/evidence.sh once per PNG so
# a full walk (~40 files) becomes one command instead of forty, and prints
# ready-to-paste markdown for the PR's Evidence section.
#
# Usage:
#   ./scripts/upload-evidence.sh --pr 936
#   ./scripts/upload-evidence.sh --pr 936 --dir output/evidence --prefix a11y-
#   pnpm run evidence && ./scripts/upload-evidence.sh --pr 936
#
# Requires EVIDENCE_UPLOAD_TOKEN (see repo-root scripts/evidence.sh, which
# this delegates every upload to — same .env resolution, same failure mode).
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_NEXT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$WEB_NEXT_ROOT/.." && pwd)"
ROOT_EVIDENCE_SH="$REPO_ROOT/scripts/evidence.sh"

PR=""
DIR="$WEB_NEXT_ROOT/output/evidence"
PREFIX=""

usage() {
	cat <<EOF
Usage: $(basename "$0") --pr <number> [options]

Options:
  --pr <number>    PR number (required)
  --dir <path>     Directory of PNGs to upload (default: output/evidence)
  --prefix <str>   Prepended to each upload's --name slug (e.g. "a11y-")
  -h, --help       Show this help

Uploads every *.png in --dir via the repo-root evidence.sh (one call per
file, --no-capture), then prints a markdown summary — pipe or redirect it
straight into the PR body's Evidence section.
EOF
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--pr)
		PR="$2"
		shift 2
		;;
	--dir)
		DIR="$2"
		shift 2
		;;
	--prefix)
		PREFIX="$2"
		shift 2
		;;
	-h | --help) usage ;;
	*)
		echo "error: unknown option: $1" >&2
		usage
		;;
	esac
done

[[ -z "$PR" ]] && {
	echo "error: --pr is required" >&2
	usage
}

[[ -d "$DIR" ]] || {
	echo "error: no such directory: $DIR (run 'pnpm run evidence' first)" >&2
	exit 1
}

shopt -s nullglob
FILES=("$DIR"/*.png)
shopt -u nullglob

[[ ${#FILES[@]} -eq 0 ]] && {
	echo "error: no .png files in $DIR" >&2
	exit 1
}

echo "Uploading ${#FILES[@]} screenshot(s) from $DIR for PR #$PR..." >&2

SUMMARY="$DIR/UPLOADED.md"
: >"$SUMMARY"

for file in "${FILES[@]}"; do
	base="$(basename "$file" .png)"
	name="${PREFIX}${base}"
	url="$("$ROOT_EVIDENCE_SH" --pr "$PR" --name "$name" --file "$file" --no-capture)"
	echo "  $name -> $url" >&2
	{
		echo "### $base"
		echo "![${name}](${url})"
		echo ""
	} >>"$SUMMARY"
done

echo "" >&2
echo "Wrote markdown summary: $SUMMARY" >&2
cat "$SUMMARY"
