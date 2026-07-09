---
name: codex-review-loop
description: Pre-PR review loop — self-reflect, then a directed codex CLI (gpt-5.5 xhigh) review, then react with attributed commits. Use before opening any substantive PR or when asked to "run the review loop" / "codex review this". Skip for metadata/docs-only diffs.
---

# Codex Review Loop

Substantive PRs go through **reflect → codex → react** before opening. The two passes catch
disjoint defects; attributed reactions make the review auditable on the PR.

## Scope gate

Code-bearing diffs only. Skip codex (reflection still applies) for metadata, changelog, or
docs-only diffs.

## The loop

1. **Reflect first — the deliverable is the attack-surface map.** Walk the diff with fresh
   eyes before invoking codex: lifecycle ordering (e.g. SwiftUI `onDisappear` vs replacement
   mounts), eviction/teardown pairing, persisted-identifier changes, PR-body claims the diff
   doesn't back. Fix what you find — but the reflection's chief *product* is the list of
   directed questions you hand the reviewer. In the W6 arc, every substantive finding traced
   back to a directed focus area written from the requestor's own diff read; the generic parts
   of the prompts produced nearly nothing. The loop's quality ceiling is set at
   question-writing time. Start from [references/attack-patterns.md](references/attack-patterns.md)
   for the surface type you're touching, then add diff-specific questions.

2. **Codex, directed.**

   ```bash
   codex exec -c model="gpt-5.5" -c model_reasoning_effort="xhigh" --skip-git-repo-check "<prompt>"
   ```

   Give it the diff command, named failure modes, and one falsifiable completeness question —
   directed prompts produce bugs; "review this" produces checklists. Templates and
   timeout/resume mechanics: [references/prompt-patterns.md](references/prompt-patterns.md).

   **Codex reviewing codex is fine.** Review independence comes from fresh context and an
   adversarial frame reading the diff as an artifact — not from model identity. W6 evidence:
   directed codex (xhigh) reviews of codex implementations found disjoint blockers the
   orchestrator review missed on every task. What *is* low-signal is the implementer reviewing
   in its own still-warm session. State the brief's scope fence in the review prompt so
   findings distinguish defects from known deferrals (reviewers re-litigate scope otherwise —
   sometimes usefully, but label it).

   Two standing questions regardless of surface: *what merged recently that changes this
   diff's assumptions?* (cross-PR interactions are otherwise caught by luck), and for UI
   diffs, *what does this do to the perf-contract surfaces?* (reviews read code; only gates
   measure — a 2x LCP regression sailed past two reviewers and was caught by the perf floor).

3. **Adjudicate.** Severity labels are advisory, and codex doesn't check whether *this* diff
   introduced a finding — run `git log <base>..HEAD -- <files>` before acting. Pre-existing
   findings become issues, not scope creep. Declining a finding is valid; say why in the PR.

4. **React with attribution.** Fix commits open with `In response to codex (gpt-5.5, xhigh) ...`;
   the PR body carries a `## Review loop` section listing each finding and its disposition.
   Never fold review reactions silently into other commits — attribution is how the loop's
   value is measured.

5. **Merge.** Green CI + no unaddressed human comments + adjudicated codex pass → merge per the
   delegated authority. Evidence and the Mergeability section still gate per AGENTS.md.
