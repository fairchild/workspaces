# Codex prompt patterns + mechanics

Directed prompts produce bugs; "review this" produces checklists. Pick the pattern by diff type.

## Mechanics

- `codex exec -c model="gpt-5.6" -c model_reasoning_effort="xhigh" --skip-git-repo-check "<prompt>"`
  — tell the prompt which diff to read (`git diff main...HEAD`, `git show HEAD`); plain `exec`
  doesn't infer it. (`codex exec review --base main` exists but cannot combine with a custom prompt.)
- 8–12 min typical at xhigh; set Bash timeout ≥ 600s. On timeout the session survives:
  ```bash
  codex exec resume --last "Output your final verdict now — findings ranked, merge-ready or not."
  ```
- Ask for output shape: "findings ranked (blocker/important/minor) with file:line and a concrete
  failure scenario; say explicitly if nothing blocks merge."
- Invite verification ("run the relevant tests", "prove it") — codex will run filtered `swift test`
  and normalized diffs itself. On audits, also ask for a "what looks sound" list; cite the
  negative results in the PR.

## Directed feature review (pre-PR)

Number the failure modes, not the topics:

> You are doing a rigorous pre-merge code review. Run 'git diff main...HEAD'. Focus areas:
> (1) WKWebView lifecycle — deferred release via tearDown → scheduleInactiveRelease; any leak,
> use-after-release, or reload regression vs the previous behavior. (2) SwiftUI correctness —
> NSViewRepresentable identity across source switches, publishing-during-update hazards,
> onDisappear sync semantics. (3) [guard placement + error-code choice] … Report findings with
> file:line, severity-ranked; call out anything that should block merge.

## Behavior-neutrality proof (renames / mechanical sweeps)

Ask for proof, not opinion — codex will normalize the rename out of the diff and compare against
the parent commit:

> Verify: (1) behavior-neutral — no logic edits smuggled in, no persisted keys / notification
> names / serialized identifiers renamed; (2) no remaining old-name references (rg the tree);
> (3) these kept types untouched: [...]

Literal gates get literal enforcement — historical mentions in ADRs/backlog will be flagged as
blockers. Adjudicate; keep the historical record.

## Adversarial audit (epic/arc close)

Bug hunt over the full arc diff with a named hunt list; demand failure scenarios:

> Adversarial bug hunt over the completed epic, not a style review. The diff under audit is
> 'git diff <pre-epic-sha>..HEAD'. Hunt specifically for: (1) lifecycle leaks or double-teardown
> [named interplay]; (2) focus regressions [named seams]; (3) state restoration [named ordering];
> … For each finding: file:line, severity, concrete failure scenario. State explicitly if the
> epic looks sound.

Expect ~200k+ tokens. Attribution check is mandatory — an arc-wide diff surfaces pre-existing
defects as if they were yours.

## Completeness challenge (small fixes)

One falsifiable question:

> Question to answer hard: is selection-transition-driven eviction complete — is there ANY path
> where the web pane unmounts but the selection never transitions to nil (window close, app
> quit, fixture/bootstrap paths)? Check how [state] interacts with [state]. Short verdict with
> any gaps.
