# CODEX Report: issue #809 mobile polish

## Changes

- `web-next/src/components/folio/status-line.tsx`
  - Changed the status-line inner row from `px-0.5` to `px-5` so its phone-width gutter matches the compose gutter directly above it.
  - Reworked the dismissed handle from a 9px button into a 44px (`h-11 w-11`) transparent button with the original 9px dot centered inside. The dot keeps the same visual size and hover behavior.
  - Added a centered 44px `::after` hit area to the status-line dismiss `✕` button, preserving the existing visible padding/layout.
- `web-next/src/components/folio/theme-toggle.tsx`
  - Added a centered 44px `::after` hit area to the theme toggle, preserving the visible `◐` mark and existing spacing.
- `web-next/tests/e2e/mobile.spec.ts`
  - Added a 375px mobile spec that asserts the status row gutter computes to `20px`, the theme toggle and status dismiss pseudo hit areas are at least 44px, and the dismissed handle's real box is at least 44px.

## Verification

- `npx pnpm@10 install` passed.
- `pnpm test` passed: 40 files, 463 tests.
- `pnpm typecheck` passed.
- `pnpm lint` passed.
- `pnpm build` passed. Next emitted existing Edge Runtime warnings from `jose`/`better-auth` during the first build, but exited 0.
- `E2E_PORT=3109 pnpm test:e2e` passed: 44 tests.
- After mutation/restore, final fixed rebuild passed: `pnpm build`.
- Final focused fixed confirmation passed: `pnpm exec playwright test tests/e2e/mobile.spec.ts -g "mobile status chrome" --project=lifecycle --workers=1 --no-deps`.

## Mutation Check

- Temporarily changed the status row gutter back to `px-0.5`.
- Rebuilt the production output so Playwright would serve the mutated source: `pnpm build`.
- Ran `pnpm exec playwright test tests/e2e/mobile.spec.ts -g "mobile status chrome" --project=lifecycle --workers=1 --no-deps`.
- Expected failure occurred in the new mobile spec:
  - `Expected: "20px"`
  - `Received: "2px"`
- Restored `px-5`, rebuilt, and reran the focused mobile spec successfully.

## Deviations

- No screenshots captured, per orchestrator instruction.
- No GitHub issue/PR actions performed.
- No files outside `web-next/` were modified except this required untracked `CODEX_REPORT.md`.
