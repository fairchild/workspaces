# Preview QA Runbook

Use this when a PR has a Vercel preview and the change needs more confidence
than CI smoke can provide. The CI lane stays cheap; local agents do the
authenticated and adversarial pass against the deployed artifact.

## Prerequisites

- The PR preview workflow must publish a raw Vercel deployment URL in its PR
  comment.
- The reusable QA host `qa.spaces-preview.cloudcompute.com` must be configured
  on the Vercel project and in DNS. Assign it to a PR preview only when
  authenticated QA is needed.
- `VERCEL_AUTOMATION_BYPASS_SECRET` must be available locally for Playwright to
  bypass Vercel Deployment Protection. Without it, use Chrome with an existing
  Vercel session as the fallback browser.
- The GitHub OAuth app callback remains
  `https://spaces.cloudcompute.com/api/auth/callback/github`; GitHub accepts
  OAuth redirect subdomains when the registrable host and path match.

## Standard Flow

```bash
mise -C web run web:preview:alias -- --pr <N>
mise -C web run web:preview:smoke -- --pr <N>
mise -C web run web:preview:auth -- --pr <N>
mise -C web run web:preview:explore -- --pr <N>
```

`web:preview:alias` reads the PR preview comment, finds the raw deployment URL,
and assigns `qa.spaces-preview.cloudcompute.com` to that deployment. This single
reusable alias is intentionally manual: most PRs only need CI smoke, and the QA
alias should point at one preview under active investigation.

`web:preview:auth` opens a headed Playwright browser, completes real GitHub
OAuth, and saves storage state under `web/.auth/`. It also captures a dashboard
screenshot under `web/output/preview-qa/`.

`web:preview:explore` reuses that storage state and runs the exploratory
Playwright project with video and trace enabled.

## Adversarial Agent Checklist

- Dashboard and repo detail pages load after refresh and direct navigation.
- Docs remain public and navigable.
- Sign-out and sign-in return to the expected dashboard route.
- Mobile viewport does not overflow or hide primary controls.
- Browser back/forward does not strand the app on loading or stale state.
- Chat and terminal tabs render their empty, paused, and unavailable states.
- Failed network requests are expected and understandable; unexpected 401, 403,
  or 500 responses are findings.
- Console errors, stuck spinners, layout overlap, and confusing reauth prompts
  are findings.

Upload notable screenshots or traces with `./scripts/evidence.sh --pr <N>`.
