# Locator priority

A hard rule. In Playwright tests you write or heal, prefer locators in this exact order:

1. **`getByRole`** with accessible name — `page.getByRole("button", { name: /send/i })`. Survives most DOM reshuffles. Works the same way screen readers work.
2. **`getByText`** — `page.getByText("Select repositories")`. Use for static copy that's unlikely to change without a PR.
3. **`getByLabel`** — `page.getByLabel("Email")`. Form-control convention.
4. **`getByTestId`** — `page.getByTestId("send-button")`. Acceptable for elements with no accessible name or stable text. Requires the app to actually set `data-testid`.
5. **CSS / XPath** — last resort. Requires a comment explaining why none of the above work.

## Forbidden without explicit justification

- Raw class selectors (`.send-button`, `.page_subtitle__YRsys`) — CSS-module hashes rot instantly.
- Positional selectors (`nth-child(3)`, `:first`, `:last`) — break on reorder.
- Full XPath paths — break on any DOM change.
- Selectors that require knowledge of internal state (`[data-reactid=...]`).

## Why

- **Resilience.** Role + accessible name is stable across style changes, DOM reshuffles, minor copy edits.
- **Oracle alignment.** Role is what assistive tech sees — it's what the *user* sees via AT. A test written in roles doubles as an a11y check.
- **Healability.** Selector drift (accessible name change) can be fixed mechanically; CSS-module drift requires re-reading the component.

## If you find yourself reaching for CSS

Stop. Ask:

1. Does this element have a role? If no role: the app is probably inaccessible — file a finding.
2. Is the accessible name ambiguous? Disambiguate with `{ name, exact }` or parent locator scoping.
3. Is the test actually about a *specific* instance among many (e.g. "the 3rd message")? Filter by role + content, not by position.

Only after those three: add `data-testid` in the app (in a separate PR — you don't edit `web/src/**` from qa-web) and use `getByTestId`.
