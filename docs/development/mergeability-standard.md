# Mergeability Standard

This is the full review standard behind the compact rule in `AGENTS.md`. Use it when opening, reviewing, or deciding whether to merge a PR.

## Core Bar

Work is mergeable when it is correct, coherent with the product, reviewable, verified, and leaves the system easier to operate.

- Solve the real user or maintainer problem, not only the narrow symptom in the first repro.
- Match existing architecture, naming, data flow, UI language, and operational conventions.
- Keep scope tight: no unrelated refactors, formatting churn, dependency changes, generated artifacts, or opportunistic rewrites.
- Prefer native-feeling, durable solutions over quick patches.
- Cover the non-happy paths a reviewer would expect: empty, loading, error, permissions, timing, focus, and recovery states.
- Preserve clear service contracts, observable failure modes, useful logs or diagnostics, and explicit production assumptions.
- Match tests and evidence to the risk and blast radius. For docs-only changes, `git diff --check` plus a clear note is usually enough.
- State what changed, how it was verified, and what residual risk or follow-up remains.
- If evidence is blocked, say so explicitly before merge and explain what approval or environment is needed.
- Use machine-readable blocker labels when a PR is not merge-ready: `blocked:ci`, `blocked:secrets`, `blocked:evidence`, or `blocked:review`.

## Required PR Body Section

The `readiness` CI gate (`scripts/pr-readiness.py`) parses the PR body for a
`## Mergeability` section with these labeled fields, each carrying a real
value — the placeholder text fails, and freeform prose under the heading does
not pass. Use the field form:

```markdown
## Mergeability

- Surface: <desktop / web / agent-runtime / infra / docs — plus what part>
- User-facing behavior changed: <what changed, or "No">
- Non-happy paths considered: <error paths / edge cases, or "n/a" with why>
- Residual risk or follow-up: <what could still break or is deferred, or "None">
```

The parser accepts near-miss labels (`Scope`, `Edge cases`, `Follow-ups`, …)
but not unlabeled narrative bullets. PRs touching release paths additionally
need a `Release/ops preconditions` field.

## Surface Checklists

### Desktop App

- The terminal-first loop remains calm: select context, get a ready terminal, inspect files or changes, keep working.
- Terminal focus, shortcut routing, restore behavior, split behavior, and no-activation behavior are considered when touched.
- UI states fit the native Mac surface: spacing, keyboard behavior, empty/error/loading states, and visible feedback are verified.
- Shared-desktop validation uses the documented no-activation and capture flow when relevant.

### Web Dashboard

- Repo scoping, auth state, loading/error/empty states, keyboard behavior, and constrained layouts are considered.
- Agent, chat, terminal, and activity surfaces stay coordinated rather than becoming parallel sources of truth.
- Accessibility and behavior coverage are reflected in `web/tests/LEDGER.md` when the behavior is user-visible and worth preserving.
- Evidence uses the web mise tasks and Playwright artifacts when runtime UI behavior changes.

### Agent Runtime

- Sandbox creation, auth/token plumbing, streaming, snapshot/restore, and terminal attach behavior are proven when touched.
- Production-like agent paths are validated when unit tests cannot cover the real failure mode.
- Logs and diagnostics make failed sandbox, stream, or provider interactions understandable without guessing.
- Public or GitHub-sourced text remains untrusted input across privileged execution boundaries.

### Infrastructure, CI, and Release

- Runner choice, secrets, permissions, rollback, and failure notifications are explicit.
- Release-sensitive PRs fill `Release/ops preconditions` in the PR template and should not merge while required secrets, credentials, or operator steps remain incomplete.
- Performance-sensitive changes include canonical before/after/delta evidence from the configured scenario contract.
- CI changes avoid bare `self-hosted` labels and preserve the repo's runner policy.
- Release/signing/notarization changes keep version metadata and artifact provenance aligned.

### Docs and Config

- Normative docs stay aligned with `AGENTS.md`, the PR template, and `docs/development/evidence.md`.
- Configuration changes explain the operational effect and any environment-specific assumptions.
- Docs-only changes should still pass `git diff --check` and mark evidence as not applicable in the PR.
