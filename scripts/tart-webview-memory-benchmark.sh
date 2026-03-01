#!/bin/bash
# ==========================================================================
# tart-webview-memory-benchmark.sh - Wrapper for UV-based Tart memory benchmark
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec uv run --script "$SCRIPT_DIR/tart-webview-memory-benchmark.py" "$@"
