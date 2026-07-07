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

1. **Reflect first.** Walk the diff with fresh eyes before invoking codex: lifecycle ordering
   (e.g. SwiftUI `onDisappear` vs replacement mounts), eviction/teardown pairing,
   persisted-identifier changes, PR-body claims the diff doesn't back. Fix what you find.

2. **Codex, directed.**

   ```bash
   codex exec -c model="gpt-5.5" -c model_reasoning_effort="xhigh" --skip-git-repo-check "<prompt>"
   ```

   Give it the diff command, named failure modes, and one falsifiable completeness question —
   directed prompts produce bugs; "review this" produces checklists. Templates and
   timeout/resume mechanics: [references/prompt-patterns.md](references/prompt-patterns.md).

3. **Adjudicate.** Severity labels are advisory, and codex doesn't check whether *this* diff
   introduced a finding — run `git log <base>..HEAD -- <files>` before acting. Pre-existing
   findings become issues, not scope creep. Declining a finding is valid; say why in the PR.

4. **React with attribution.** Fix commits open with `In response to codex (gpt-5.5, xhigh) ...`;
   the PR body carries a `## Review loop` section listing each finding and its disposition.
   Never fold review reactions silently into other commits — attribution is how the loop's
   value is measured.

5. **Merge.** Green CI + no unaddressed human comments + adjudicated codex pass → merge per the
   delegated authority. Evidence and the Mergeability section still gate per AGENTS.md.
