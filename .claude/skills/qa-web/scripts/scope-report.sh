#!/usr/bin/env bash
# qa-web Phase 0 scope report — git + gh reconnaissance.
# Usage: scope-report.sh [caller-summary]
# Prints a draft Scope Report (branch state, diff summary, PR context, caller summary).
# The agent enriches it with surface classification + ledger cross-ref.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not inside a git repo" >&2; exit 1; }
cd "$REPO_ROOT"

CALLER_SUMMARY="${1:-}"
BRANCH=$(git branch --show-current)
DATE=$(date -u +%Y-%m-%d)

echo "## Phase 0 — Scope Report (draft)"
echo ""
echo "**Date:** $DATE"
echo "**Branch:** $BRANCH"

if [[ "$BRANCH" == "main" ]]; then
  echo ""
  echo "On \`main\` — no branch changes. Skip Phase 0; run Phase 1 with default scope or as directed."
  exit 0
fi

AHEAD=$(git rev-list --count main..HEAD 2>/dev/null || echo 0)
UNCOMMITTED=$(git status --porcelain | wc -l | tr -d ' ')
echo "**Commits ahead of main:** $AHEAD"
echo "**Uncommitted changes:** $UNCOMMITTED files"

echo ""
echo "### Commit subjects (main..HEAD, web/ only)"
echo ""
if [[ "$AHEAD" -gt 0 ]]; then
  git log --oneline main..HEAD -- web/ | sed 's/^/- /' || echo "_none_"
else
  echo "_no commits ahead_"
fi

echo ""
echo "### File changes (working tree vs main, web/)"
echo ""
echo '```'
git diff --stat main -- web/ || echo "no changes"
echo '```'

echo ""
echo "### File list (working tree vs main, web/)"
echo ""
git diff --name-only main -- web/ 2>/dev/null | sed 's/^/- /' || echo "_none_"

echo ""
echo "### PR context"
echo ""
if gh pr status --json number,title,state,isDraft,labels,headRefName 2>/dev/null > /tmp/qa-pr.json && [[ -s /tmp/qa-pr.json ]]; then
  CURRENT_PR=$(jq -r '[.createdBy[], .needsReview[]] | map(select(.headRefName == "'"$BRANCH"'")) | .[0] // empty' /tmp/qa-pr.json 2>/dev/null)
  if [[ -n "$CURRENT_PR" ]]; then
    PR_NUM=$(echo "$CURRENT_PR" | jq -r '.number')
    PR_TITLE=$(echo "$CURRENT_PR" | jq -r '.title')
    PR_STATE=$(echo "$CURRENT_PR" | jq -r '.state // "open"')
    PR_DRAFT=$(echo "$CURRENT_PR" | jq -r '.isDraft')
    echo "- **PR:** #$PR_NUM — $PR_TITLE ($PR_STATE${PR_DRAFT:+, draft})"
    echo ""
    echo "#### PR body"
    echo ""
    echo '```'
    gh pr view "$PR_NUM" --json body --jq '.body' 2>/dev/null | head -40 || echo "(unavailable)"
    echo '```'
    echo ""
    echo "#### CI checks"
    echo ""
    gh pr checks "$PR_NUM" 2>&1 | head -20 || echo "(no checks yet)"
  else
    echo "- No PR open for \`$BRANCH\` yet."
  fi
else
  echo "- \`gh\` not authenticated or API unreachable. Run \`gh auth login\` to enable PR context."
fi

echo ""
echo "### Caller summary"
echo ""
if [[ -n "$CALLER_SUMMARY" ]]; then
  echo "> $CALLER_SUMMARY"
  echo ""
  echo "_Treat as authoritative intent. If the diff says something different, note the discrepancy; the summary wins._"
else
  echo "_Not provided. Derive scope from the diff alone._"
fi

echo ""
echo "---"
echo ""
echo "**Next:** classify changed files → user surfaces, cross-reference \`web/tests/LEDGER.md\`, and emit the full Exploration plan."
echo "See: .claude/skills/qa-web/references/scope.md § 'Classify changed files → user surfaces'"
