# web/specs — behavior specs for qa-web-agent

This directory holds Markdown specifications of user-facing behaviors, written *before* the corresponding test code. `qa-web-agent` produces these during its Author phase; a human reviews and approves them; then Playwright's Generator turns them into `.spec.ts` files under `web/e2e/`.

## Why spec-first

A test written from the implementation tends to mirror the implementation — and mirror-tests don't catch bugs. A test written from a spec is anchored to behavior a user cares about. If the implementation changes but the behavior is still correct, the test still passes. If the behavior changes, the test correctly fails.

## Spec template

```markdown
# Behavior: <imperative statement of what the user can do or observe>

## Preconditions
- <what must be seeded / signed in / URL state>

## Steps
1. <user-visible step — click, type, navigate>
2. ...

## Assertions (the oracle)
- <observable outcome — role, text, URL, network response, absence of errors>

## Negative cases
- <what should NOT happen>

## Notes
- **Viewport**: desktop (1440×900) / mobile (375×667) / both
- **Layer**: e2e-full / e2e-fast / integration / unit
- **Why E2E and not integration**: <justification, or "promote to src/**/__tests__/">
```

## Flow

1. `qa-web-agent` writes a spec here from an exploratory finding or an uncovered behavior in `web/tests/LEDGER.md`.
2. A human reviews the spec. Common feedback: wrong oracle, missing negative case, wrong layer.
3. On approval, `mise run web:qa:generate` invokes Playwright's Generator (Test Agents 1.56+), which writes `web/e2e/<layer>/<slug>.spec.ts` with live-verified selectors.
4. `web/tests/LEDGER.md` gets a new row.
5. The spec stays in this directory as the durable source of intent — do not delete specs after generation.

## Naming

Slugs are kebab-case and should match the generated test file: `chat-send-enabled-on-typing.md` → `web/e2e/full/chat-send-enabled-on-typing.spec.ts`.
