---
name: codex-review-loop
description: Pre-PR review loop for this repo — self-reflect, then a directed codex CLI (gpt-5.5 xhigh) review, then react with attributed commits. Use before opening any substantive PR, when asked to "run the review loop", "codex review this", or when a PR is about to be declared ready. Skip for metadata/docs-only diffs.
---

# Codex Review Loop

Every substantive PR goes through **reflect → codex → react** before it opens. The loop exists
because the two passes catch disjoint defect sets (measured 2026-07-06: the deepest bug of the
tile-tree epic came from reflection; codex caught four real gaps reflection missed), and because
attributed reactions make the review approach itself auditable on the PR.

## Scope gate

Run the loop for code-bearing diffs. **Skip codex** (reflection still applies) for metadata,
changelog, or docs-only diffs — measured worst value per minute; a 2-file version bump does not
need a 10-minute xhigh review.

## The loop

1. **Reflect first, with your full context.** Walk the diff with fresh eyes before invoking
   anything: lifecycle ordering (SwiftUI `onDisappear` vs mounts), eviction/teardown pairing,
   persisted-identifier changes, claims your PR body makes that the diff doesn't back. Fix what
   you find; don't outsource what your context already knows.

2. **Codex, directed.** Run against the committed diff:

   ```bash
   codex exec -c model="gpt-5.5" -c model_reasoning_effort="xhigh" --skip-git-repo-check "<prompt>"
   ```

   Prompt quality determines finding quality — give it the diff command, named focus areas, and
   at least one falsifiable completeness challenge. Patterns that measurably worked (rename
   neutrality proof, adversarial audit, completeness challenge) and the timeout/resume mechanics:
   see [references/prompt-patterns.md](references/prompt-patterns.md).

3. **Adjudicate — severity is advisory, attribution is yours.** Codex applies the letter of your
   gates ("no old names anywhere" → historical doc mentions become "blocks merge") and does not
   check whether *this* diff introduced a finding. Before acting: `git log <base>..HEAD -- <files>`
   to attribute; pre-existing findings become issues, not scope creep. Declining a finding is a
   valid reaction — say why in the PR.

4. **React with attribution.** Fixes land as commits whose messages open with
   `In response to codex (gpt-5.5, xhigh) ...`; the PR body carries a `## Review loop` section
   naming what codex found and what was done with each finding. This attribution is the
   measurement signal for whether the loop is working — never fold review reactions silently
   into other commits.

5. **Merge policy.** Green CI + no unaddressed human comments + codex pass (or findings all
   adjudicated) → merge per the delegated authority. Evidence and the Mergeability section still
   gate per AGENTS.md; this loop replaces the paused GitHub review agents, not the evidence bar.
