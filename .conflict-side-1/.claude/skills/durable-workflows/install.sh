#!/bin/bash
set -euo pipefail

SKILL_DIR="${HOME}/.claude/skills/durable-workflows"

echo "Installing durable-workflows skill..."

# Copy skill files
mkdir -p "$SKILL_DIR"
rsync -a --exclude node_modules --exclude .spike-data --exclude .dbos \
  "$(dirname "$0")/" "$SKILL_DIR/"

# Install dependencies
cd "$SKILL_DIR" && npm install --silent

echo "✓ Installed to $SKILL_DIR"
echo ""
echo "Usage in Claude Code:"
echo "  Mention 'durable workflow' or use /durable-workflows"
echo ""
echo "Quick start:"
echo "  cd $SKILL_DIR && npx tsx scripts/bootstrap.ts"
