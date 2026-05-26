---
status: done
issue: 546
completed: 2026-05-25
resolution: promoted-to-github-issue
topic: pr-reviewer
priority: 2
description: Convert the recent PR reviewer narration analysis into a small skill-backed preference eval harness for fine-tuning narrative, evidence, and label behavior.
---

# PR Reviewer Narration Eval Skill

## Problem Statement

The managed PR reviewer now has three judgment surfaces beyond normal code review: `## Project Thread` narration, evidence sufficiency, and label reasoning. Recent PRs show the reviewer is improving, but the tuning process is still conversational and ad hoc. We need a repeatable way to collect recent reviewer output, present small A/B preference choices, and convert user feedback into narrow prompt/context refinements.

This work should become a skill and eval harness for future sessions, not a radical rewrite of the managed reviewer. The production managed reviewer does not currently load Codex/Claude skills. It receives a trusted static system prompt and server-fetched PR context from `web/src/lib/agent-runtime/pr-review.ts`. The skill should be the lab: gather examples, produce preference items, collect feedback, and recommend small production prompt/context changes.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Runtime boundary | Keep the deployed managed reviewer prompt in `web/src/lib/agent-runtime/pr-review.ts`; do not rely on runtime skill loading | Managed Agents sessions do not automatically load local `SKILL.md` files, and loading skill instructions from a PR branch would introduce prompt-injection risk |
| Skill role | Create a repo skill for evaluation and improvement, not live review execution | The workflow is repeatable, judgment-heavy, and benefits from a stable rubric and scripts |
| Eval format | Use small pairwise preference items with one dimension each | The user wants fine-tuning; narrow A/B choices are easier to align than reviewing entire PR review bodies |
| Dimensions | Start with `thread_narrative`, `evidence_judgement`, and `label_reasoning` | These are the three behaviors recently added to the reviewer |
| Feedback vocabulary | Capture `A`, `B`, `tie`, or `neither` plus short rationale tags | This keeps review lightweight while preserving useful training signal |
| Initial scope | Seed from recent PRs #431, #433-#443 | These include clear positive examples, evidence-boundary cases, label suggestions, and new-thread cases |
| Change policy | Treat eval feedback as prompt/context fine-tuning only until repeated failures justify code changes | Avoid overfitting or destabilizing a reviewer that is already mostly working |

## Current Architecture

```text
GitHub PR opened
   |
   v
web/src/app/api/webhooks/github/route.ts
   |
   v
triggerPrReview(payload)
   |
   +--> fetchPrNarrativeContext()
   +--> fetchPrEvidenceContext()
   |
   v
Managed Agent session
   |
   +--> trusted SYSTEM_PROMPT from pr-review.ts
   +--> kickoff message with PR body, prior PR context, comments, labels
   +--> mounted repo + GitHub token file
   |
   v
GitHub PR review

Planned eval skill
------------------
human / Codex session
   |
   v
.agents/skills/pr-reviewer-narration-evals/SKILL.md
   |
   +--> collect recent PRs + managed reviews
   +--> extract Project Thread / Evidence / label rationale
   +--> generate pairwise eval items
   +--> collect human preferences
   |
   v
small recommended updates to pr-review.ts prompt/context
```

## Initial Eval Shape

Use JSONL so future scripts can append and filter easily.

```json
{
  "id": "pr-443-thread-v1",
  "dimension": "thread_narrative",
  "current_pr": {
    "number": 443,
    "title": "feat: claude code hook integration",
    "labels": ["area: platform"],
    "body_summary": "First PR in a five-PR Claude Code hook integration plan."
  },
  "key_context": {
    "recent_prs": [
      {
        "number": 442,
        "title": "Fix deployment-safe web smoke validation",
        "labels": ["area: platform", "web"],
        "relationship": "CD/web infra"
      },
      {
        "number": 438,
        "title": "Add become persona skill",
        "labels": ["area: platform"],
        "relationship": "agent/persona tooling"
      }
    ],
    "policy": "Reference a previous PR if clearly related; otherwise say this starts a new thread."
  },
  "outcome_a": {
    "source": "actual-review",
    "text": "This is a new feature area with no direct predecessor among the relationship candidates..."
  },
  "outcome_b": {
    "source": "candidate-rewrite",
    "text": "This starts a new Claude Code integration thread. The closest adjacent prior is #438..."
  },
  "preference": null,
  "rationale": null,
  "tags": []
}
```

Preference tags should start small:

- `wrong_prior`
- `right_prior_weak_explanation`
- `new_thread_handled_well`
- `too_strict`
- `too_lenient`
- `evidence_good`
- `evidence_bad`
- `label_over_applied`
- `label_under_applied`
- `label_good`

## Seed Cases

| PR | Dimension | Why it belongs in the first eval set |
|----|-----------|--------------------------------------|
| #431 | `thread_narrative` | Strong continuation to #426; good positive example for narrative continuity |
| #433 | `label_reasoning` | Good `security` label plus useful `test-coverage` label suggestion |
| #435 | `thread_narrative` | Ideal self-improvement arc: #430 -> #434 -> #435 |
| #438 | `thread_narrative` | Good "no direct predecessor / new platform tool thread" case |
| #439 | `evidence_judgement` | Boundary case where structural proof was accepted without hosted evidence |
| #440 | `evidence_judgement` | Infra/release evidence accepted from detailed command list |
| #441 | `evidence_judgement` | Request-changes solely for missing evidence despite clean code |
| #442 | `evidence_judgement` | Request-changes for missing evidence, then later comment says evidence was added |
| #443 | `thread_narrative` | New root thread where same-label/same-path candidates may matter more than updated-order candidates |
| #443 | `evidence_judgement` | Local-only evidence paths and missing hosted upload on a large behavioral PR |

## Implementation Phases

### Phase 1: Create the Skill Skeleton

**Files to create:**
- `.agents/skills/pr-reviewer-narration-evals/SKILL.md` - workflow for collecting reviewer examples, generating pairwise evals, and summarizing prompt recommendations
- `.agents/skills/pr-reviewer-narration-evals/references/rubric.md` - concise rubric for narrative, evidence, and labels
- `.agents/skills/pr-reviewer-narration-evals/templates/preference-item.json` - schema example for one eval item

**Acceptance criteria:**
- [ ] Skill clearly states that it evaluates and tunes the reviewer; it is not loaded by the production Managed Agent
- [ ] Skill tells future sessions to keep recommendations small and evidence-backed
- [ ] Skill includes the A/B/tie/neither feedback vocabulary

### Phase 2: Add a Minimal Collector Script

**Files to create:**
- `.agents/skills/pr-reviewer-narration-evals/scripts/collect-pr-reviewer-evals.py` - executable UV script that uses `gh` to fetch PR metadata, labels, comments, managed-review bodies, and extracted review sections

**Script behavior:**
- Accept `--repo owner/name`
- Accept either `--prs 431,433-443` or `--limit N`
- Extract:
  - PR title, state, labels, body summary
  - managed reviewer state and review body
  - `## Project Thread`
  - `## Evidence`
  - label rationale trailers
  - recent comments that mention evidence or Vercel preview
- Write compact JSONL to `evals/pr-reviewer-narration/raw.jsonl`

**Acceptance criteria:**
- [ ] Script is a single-file UV script with PEP 723 metadata
- [ ] Script fails with a clear message if `gh` is unavailable or unauthenticated
- [ ] Output is deterministic for the same PR list

### Phase 3: Generate the Simple Human Review Harness

**Files to create:**
- `evals/pr-reviewer-narration/items.jsonl` - pairwise eval items
- `evals/pr-reviewer-narration/review-sheet.md` - simple Markdown sheet for human preference review
- `evals/pr-reviewer-narration/preferences.jsonl` - append-only user feedback

**Acceptance criteria:**
- [ ] Each item has exactly one dimension
- [ ] Each item includes only the key context needed to choose a preference
- [ ] Outcomes are short enough to compare quickly
- [ ] The review sheet can be read in a normal GitHub/Markdown view without a custom app
- [ ] The harness can later be swapped into `skill-creator`'s `eval-viewer/generate_review.py` flow if needed

### Phase 4: Convert Preferences Into Prompt Recommendations

**Files to modify:**
- `.agents/skills/pr-reviewer-narration-evals/SKILL.md` - add the finalized synthesis workflow after the first preference pass
- `web/src/lib/agent-runtime/pr-review.ts` - only if repeated evals justify a production prompt/context change
- `web/src/lib/agent-runtime/__tests__/pr-review.test.ts` - assert any production prompt/context contract changes

**Likely fine-tuning candidates:**
- Add relationship taxonomy: `causal`, `same surface`, `coordination overlap`, `new root thread`
- Treat "new thread" as a successful outcome when no prior PR is clearly related
- Supplement updated-order candidate scanning with same-label or same-path candidates
- Require re-checking comments when a prior review requested evidence and a later comment claims evidence was added
- Tighten evidence language around when structural proof is enough without hosted evidence

**Acceptance criteria:**
- [ ] Recommendations are tied to multiple preference examples, not a single anecdote
- [ ] Production prompt changes remain narrow and test-covered
- [ ] No runtime skill loading is added unless there is a separate trusted-source design

## Verification Commands

```bash
# Skill file sanity
python3 -m json.tool .agents/skills/pr-reviewer-narration-evals/templates/preference-item.json

# Collector smoke once implemented
uv run --script .agents/skills/pr-reviewer-narration-evals/scripts/collect-pr-reviewer-evals.py \
  --repo fairchild/workspaces \
  --prs 431,433-443 \
  --out evals/pr-reviewer-narration/raw.jsonl

# Eval JSONL sanity
python3 - <<'PY'
import json
from pathlib import Path
for line in Path("evals/pr-reviewer-narration/items.jsonl").read_text().splitlines():
    json.loads(line)
print("items.jsonl ok")
PY

# If production prompt changes are made
mise -C web run web:check
```

## Rollback Plan

If the skill/eval harness proves too heavy:

1. Keep the rubric as a plain doc under `evals/pr-reviewer-narration/`.
2. Drop the collector script and continue manually pasting PR context into the review sheet.
3. Do not modify `web/src/lib/agent-runtime/pr-review.ts` unless human preference data clearly indicates a recurring issue.

If a production prompt change makes reviewer output worse:

1. Revert only the prompt/context delta in `web/src/lib/agent-runtime/pr-review.ts`.
2. Keep the eval items and preferences as evidence for the next attempt.
3. Add the failed case to the eval set before trying another prompt change.

## References

- `web/src/lib/agent-runtime/pr-review.ts` - production managed PR reviewer prompt and kickoff context
- `web/src/lib/agent-runtime/__tests__/pr-review.test.ts` - prompt/context contract tests
- `web/src/app/api/webhooks/github/route.ts` - webhook payload assembly for PR review kickoff
- `.agents/skills/skill-creator/SKILL.md` - skill creation and human eval workflow
- Recent reviewer rollout PRs:
  - #430 Teach PR reviewer narrative labels
  - #434 Add PR reviewer label intelligence
  - #435 Add PR reviewer evidence judgement
- Initial eval observation PRs:
  - #431, #433, #435, #438, #439, #440, #441, #442, #443
