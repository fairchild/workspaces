# Spaces Web

Next.js dashboard for the Workspaces app — chat with AI agents, manage sandbox sessions, and access terminal shells directly in the browser.

## Stack

- **Next.js 15** with App Router
- **Better Auth** for GitHub OAuth
- **LibSQL / Kysely** for persistence
- **ghostty-web** (WASM-compiled Ghostty) for browser terminal
- **Compute provider registry** for agent compute (Vercel Sandbox and Anthropic Managed Agents; Daytona/GitHub Actions stubs; mock for tests)
- **Biome** for linting
- **Vitest** for unit tests, **Playwright** for E2E
- **pnpm** package manager

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full system diagram, agent runtime, and terminal proxy design.

## Development

```bash
pnpm install
pnpm dev

# With auth bypass (no GitHub OAuth needed):
DEV_BYPASS_AUTH=1 pnpm dev

# Run tests:
pnpm test                    # unit tests (vitest)
pnpm exec playwright test    # E2E tests
```

Optional PostHog client telemetry:

```bash
NEXT_PUBLIC_POSTHOG_TOKEN=phc_xxx
NEXT_PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
```

## Deploy

Deployed to Vercel with root directory set to `web/`.

Infrastructure workers deployed separately:
- `infra/cloudflare-webhook-relay/` — GitHub webhook ingestion
- `infra/cloudflare-evidence-store/` — PR evidence uploads
