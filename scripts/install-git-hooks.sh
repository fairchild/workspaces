#!/usr/bin/env bash
# ==========================================================================
# install-git-hooks.sh - Compatibility wrapper for prek hook installation
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=> scripts/install-git-hooks.sh is a compatibility wrapper; use ./scripts/setup for first-run setup."
exec "$SCRIPT_DIR/setup" --hooks-only
