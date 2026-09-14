# Mergeability Standard

This is the full review standard behind the compact rule in `AGENTS.md`. Use it when opening, reviewing, responding to review, or deciding whether to merge a PR.

## Core Bar

Work is mergeable when it is correct, coherent with the product, reviewable, verified, and leaves the system easier to operate.

- Solve the real user or maintainer problem, not only the narrow symptom in the first repro.
- Match existing architecture, naming, data flow, UI language, and operational conventions.
- Keep scope tight: no unrelated refactors, formatting churn, dependency changes, generated artifacts, or opportunistic rewrites.
- Prefer native-feeling, durable solutions over quick patches.
- Cover the non-happy paths a reviewer would expect: empty, loading, error, permissions, timing, focus, and recovery states.
- Preserve clear service contracts, observable failure modes, useful logs or diagnostics, and explicit production assumptions.
- Match tests and evidence to the risk and blast radius. For docs-only changes, `git diff --check` plus a clear note is usually enough.
- Visual changes ship visual evidence: before/after screenshots (or after-only when the before state is gone or irrelevant) for any user-visible UI change, captured via the fixture lane, the capture-only handshake, or a VM lane. Narrative-only claims do not clear the gate; if capture is genuinely blocked, mark `blocked:evidence` with the reason.
- State what changed, how it was verified, and what residual risk or follow-up remains.
- If evidence is blocked, say so explicitly before merge and explain what approval or environment is needed.
- Use machine-readable blocker labels when a PR is not merge-ready: `blocked:ci`, `blocked:secrets`, or `blocked:evidence`. (`blocked:review` was deleted in the 2026-08-02 label hygiene sweep as unused; a PR needing revision after review simply stays on `review` until fixed — no separate blocker label covers that state.)

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

Bodies are most accurate when they start from the contract rather than from
memory: copy `.github/pull_request_template.md`, fill it in, and run the gate
against the file before publishing — `uv run --script scripts/pr-readiness.py
--body-file <path>` gives the same verdict in the same words CI will, one step
earlier. Producers that generate bodies read their field list out of that same
template, so a field added there reaches generated PRs without a second edit.

PR summary style: prefer concise Markdown links for completed checks and
artifacts — link the check name, e.g. `Web CI passed`, to the run URL.
Readability preference, not a merge gate.

## Review handoff and response

This workflow applies to Interactive Lane agents handing work to Factory or a
human reviewer. Factory's runtime owns its automated response and revision
routing; an Interactive Lane agent must not impersonate that runtime.

Before requesting review, establish how the intended reviewer will inspect the
required artifacts. A link that opens on your laptop proves access there. For
Factory visual evidence, require a delivery result for this PR's artifacts
before claiming reviewer access; absent that result, access is unknown. Factory should inspect
images itself. An implementing or independent agent's attestation supplements
that inspection; a human intervenes when the required capability or judgment is
unavailable.

Prepare one handoff tied to the reviewed commit: named checks and results,
artifacts and the claim each proves, and the source state used for capture. See
[evidence delivery and provenance](evidence.md#delivery-and-provenance).
Gather related body changes in a local file and run the existing body preflight
before publishing them together. A preflight pass checks the body contract; it
does not establish artifact delivery or visual correctness. Keep incomplete
handoffs in draft. Correct material false statements promptly, but avoid
cosmetic body edits that trigger another review.

On feedback, refresh the current head, checks, standing reviews, and unresolved
threads. For each actionable finding, retain its review or thread ID, requested
outcome, evidence, and next action. Classify the objection before responding:

| Objection | Action |
| --- | --- |
| Code defect | Establish the defect, fix it, and run relevant checks. |
| Missing or stale evidence | Supply the artifact that proves the requested outcome; refresh evidence affected by code changes. |
| Reviewer capability failure | Identify the failed delivery or inspection step and route it to the tooling owner. |
| Policy or scope disagreement | Compare the claim with the exact repository-owned rule. Correct a mistaken claim once with that source; involve the Owner when intent, scope, or authority remains unsettled. |

Continue independent authorized fixes while another finding is blocked. Answer
findings in their original threads with the change or evidence, and publish
related PR-body updates together. Do not change Factory settings or expand your
write scope to clear a review unless already authorized.

Before another review attempt, name the changed input that can clear its
blocker: code, evidence content or delivery, reviewer capability, relevant
policy, or an Owner decision. A new review ID or rewritten explanation is not
a changed blocking condition. If nothing relevant changed, stop retriggering
review and report the owner and resume event once. Pause a bounded watch when
no machine work is progressing and the next action requires that event. An
explicit Owner request can authorize another attempt; record that reason.

Report implementation validation, evidence availability to the intended
reviewer, and review approval separately, including unknowns. Review approval
does not authorize merge or deployment. Preserve standing review decisions;
neither the author's own inspection nor a weakened evidence rule clears them.

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
