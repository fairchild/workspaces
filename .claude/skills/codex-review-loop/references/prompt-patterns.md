# Codex prompt patterns + mechanics

Patterns proven on the tile-tree epic (PRs #841/#842/#849/#853, 2026-07-06). Findings-per-review
was highest when the prompt named failure modes and asked falsifiable questions; "review this"
prompts produce checklists, directed prompts produce bugs.

## Mechanics

- Invoke: `codex exec -c model="gpt-5.5" -c model_reasoning_effort="xhigh" --skip-git-repo-check "<prompt>"`.
  Tell the prompt which diff to read (`git diff main...HEAD`, `git show HEAD`, or an explicit
  range) — plain `exec` doesn't infer it.
- `codex exec review --base main` exists but **cannot combine with a custom prompt**; use plain
  `exec` when you want directed instructions (almost always).
- **Latency**: 8–12 min typical at xhigh; budget the Bash timeout ≥ 600s. On timeout the session
  survives — recover the verdict with:
  ```bash
  codex exec resume --last "Output your final verdict now — findings ranked, merge-ready or not."
  ```
- Ask for output shape: "findings ranked by severity (blocker/important/minor) with file:line and
  a concrete failure scenario; say explicitly if nothing blocks merge."
- Codex runs its own verification (filtered `swift test`, normalized diffs) when the prompt
  invites it — that verification is often more valuable than the findings list. Also ask for a
  "what looks sound" list on audits; negative results are confidence you can cite in the PR.

## Pattern: directed feature review (pre-PR)

Name the focus areas as numbered failure modes, not topics:

> You are doing a rigorous pre-merge code review. Run 'git diff main...HEAD' … Focus areas:
> (1) WKWebView lifecycle — deferred release via tearDown → scheduleInactiveRelease; any leak,
> use-after-release, or reload regression vs the previous behavior. (2) SwiftUI correctness —
> NSViewRepresentable identity across source switches, publishing-during-update hazards,
> onDisappear sync semantics. (3) [guard placement + error-code choice] … Report concrete
> findings with file:line, severity-ranked; call out anything that should block merge.

## Pattern: behavior-neutrality proof (renames / mechanical sweeps)

Ask for proof, not opinion — codex will normalize the rename out of the diff and compare
against the parent commit:

> Verify: (1) it is behavior-neutral — no logic edits smuggled in, no persisted keys /
> notification names / serialized identifiers renamed; (2) no remaining references to the old
> names anywhere (rg the tree); (3) these kept types were not touched: [...]

Caveat: literal gates get literal enforcement — historical mentions in ADRs/backlog will be
flagged as blockers. Adjudicate; keep the historical record.

## Pattern: adversarial audit (epic/arc close)

Frame as a bug hunt with a named hunt list, over the full arc diff, and demand failure scenarios:

> Adversarial bug hunt over the completed epic, not a style review. The diff under audit is
> 'git diff <pre-epic-sha>..HEAD'. Hunt specifically for: (1) lifecycle leaks or double-teardown
> [named interplay]; (2) focus regressions [named seams]; (3) state restoration [named ordering];
> … For each finding: file:line, severity, and a concrete failure scenario. State explicitly if
> the epic looks sound.

Expect ~200k+ tokens and the strongest findings of the loop. Attribution check is mandatory
here — an arc-wide diff surfaces pre-existing defects as if they were yours.

## Pattern: completeness challenge (small fixes)

The best small-diff prompt is one falsifiable question:

> Question to answer hard: is selection-transition-driven eviction complete — is there ANY path
> where the web pane unmounts but the selection never transitions to nil (window close, app
> quit, fixture/bootstrap paths)? Check how [state] interacts with [state] in this codebase.
> Short verdict with any gaps.

This pattern found the window-close teardown gap that a generic "review this commit" pass on the
same diff did not.
