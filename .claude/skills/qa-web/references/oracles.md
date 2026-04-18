# Oracles for exploration

Heuristics for Phase 1. An oracle is a principle by which you recognize a problem. Load this file when you're about to explore a surface and need a structured checklist.

## SFDIPOT — "San Francisco Depot"

For each surface, ask:

- **Structure** — What is it made of? What pieces compose it? (tabs, panels, forms, lists)
- **Function** — What does it do? Primary, secondary, and implicit actions.
- **Data** — What does it operate on? Inputs, outputs, state, persistence.
- **Interfaces** — What does it communicate with? Keyboard, mouse, URL, API, storage.
- **Platform** — What does it depend on? Browser, viewport, OS, auth state.
- **Operations** — How will people use it? Fast typing, long delay, tab-switch, reload.
- **Time** — What temporal dimensions matter? First load, repeated action, long session, clock skew.

Walk each axis with a "what could go wrong?" lens.

## FEW HICCUPPS — consistency oracles

A thing is probably wrong when it violates:

- **History** — It used to work differently. Regression.
- **Explainability** — You can't explain why this is what it is. Surprise.
- **World** — Doesn't match how similar things work in the world. Phone numbers, dates, currency.
- **User expectations** — A reasonable user would expect something else.
- **Image** — Cosmetic inconsistency; logo-vs-brand mismatch; broken visuals.
- **Comparable products** — Competitors or sibling features do it better.
- **Claims** — The docs, marketing, or UI copy says it does X; it doesn't.
- **Users' desires** — It does what was asked but not what was wanted.
- **Product** — Internal inconsistency: one button says "Save" another says "Update"; date formats differ across pages.
- **Purpose** — It doesn't serve the stated purpose.
- **Statutes & standards** — Violates a standard (WCAG, RFC, platform HIG).

When in doubt, ask "which oracle caught it?" If you can't name one, it may not be a finding.

## Applying oracles to this app

- **SFDIPOT / Platform** — 1440×900 desktop + 375×667 mobile is the minimum matrix. Test both before logging a finding.
- **FEW HICCUPPS / Statutes** — axe-core violations map here. Critical → P0. Serious → P1. Moderate → `[gap]` candidate if not covered.
- **FEW HICCUPPS / History** — `git log` on the changed files gives you recent "used to work differently" signal.
- **SFDIPOT / Data** — dev fixtures (`e2e-*` prefixed rows) are seeded by `web/e2e/seed.ts`. When testing empty states, use a repo that has no seeded data.
- **SFDIPOT / Time** — snapshot/restore in agent chat, SSE reconnects in terminal, session expiry after token refresh.

## What's NOT an oracle

- "It feels slow" — without a baseline, not actionable. Measure.
- "I'd design it differently" — personal preference is not a defect. Use `Claims` or `User expectations` with evidence.
- "The code is ugly" — not your problem in Phase 1. Close the file.
