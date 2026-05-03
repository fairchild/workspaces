# e2e/explore — qa-web-agent exploration surface

This Playwright project is the sandbox where `qa-web-agent` runs its black-box exploratory passes. It is separate from `fast`/`full`/`demo` so exploratory runs never gate CI on findings that are still being triaged.

## What's here

- `axe-fixture.ts` — a Playwright fixture that wires `@axe-core/playwright` into the test context, so every exploratory test can call `await axe()` and get WCAG violations.
- Exploratory specs that the agent writes here are short, focused, and produce evidence under `output/qa-agent/<ISO-date>/<slug>/`. They are not expected to be green on every CI run — they are probes.

## Running locally

```bash
mise run web:e2e:explore
```

Video and trace are always on for this project. Artifacts land under `web/playwright-report/`.

## Relationship to `web/e2e/full/`

When an exploratory spec finds a behavior worth locking in, `qa-web-agent` promotes it via its Author phase:
1. Write a spec under `web/specs/<slug>.md`.
2. Human approves.
3. `mise run web:qa:codegen [url]` launches interactive Playwright codegen so the author can record the durable test under `web/e2e/full/<slug>.spec.ts`.
4. `web/tests/LEDGER.md` gets a row.

The exploratory spec can then be deleted — the durable test is the new source of truth.
