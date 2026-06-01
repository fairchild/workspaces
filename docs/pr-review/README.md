# Managed PR Review

This directory is the entry point for the WorkSpaces managed PR reviewer.

Start with the visual [`index.html`](index.html) when you need a high-level,
progressive explanation of the system before diving into implementation detail.
Use [`architecture.md`](architecture.md) when you need the current ReviewRun
model, lifecycle vocabulary, diagrams, and operator triage surfaces. Use
[`understanding-guide.md`](understanding-guide.md) and
[`scripts/pr-reviewer-quiz.py`](../../scripts/pr-reviewer-quiz.py) when someone
needs to learn the system through scenarios before operating or changing it. Use
[`pr-reviewer.md`](pr-reviewer.md) for runtime configuration, webhook ingress,
broker scheduling, canaries, and debugging commands. The current storage
reference in [`review-run-schema.sql`](review-run-schema.sql) mirrors the
ReviewRun-centered tables used by the web runtime. Use
[`milestone-validation.md`](milestone-validation.md) for the latest closure
evidence and maintainer understanding check.

The operational rule is simple: **ReviewRun rows are the source of truth**.
GitHub commit statuses, GitHub reviews, dashboard pages, and health reports are
derived surfaces that should be checked against the run record when behavior
looks inconsistent.
