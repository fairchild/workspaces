# WorkSpaces Docs Site

This directory contains the static documentation site for the native WorkSpaces app. The site has three layers:

- `index.html` is the high-level landing page for the native app model.
- Extensionless paths such as `/docs/development/libghostty-integration` are rendered documentation pages.
- `.md` paths such as `/docs/development/libghostty-integration.md` are raw Markdown source.

The Markdown files remain the source of truth. The sync step generates rendered static pages from the shared reader template so local and deployed navigation use the same path-based model.

## Published Route

The public docs route is:

```text
https://spaces.cloudcompute.com/docs
```

The Vercel deployment serves this through the existing `web/` Next.js app. Root documentation stays canonical here; `web/scripts/docs-sync.mjs` copies the curated native WorkSpaces docs and required assets into `web/public/docs` before `next dev` and `next build`.

## Architecture

The docs site is intentionally a static shell over canonical Markdown, not a second documentation source.

- Root Markdown remains editable source content.
- `web/scripts/docs-sync-manifest.json` defines the curated native WorkSpaces docs that are safe to publish.
- Manifest entries carry each document's group, summary, and domain topics. The reader uses that metadata for calm related-doc navigation instead of scraping arbitrary Markdown.
- `web/scripts/docs-sync.mjs` copies that curated set into `web/public/docs` for Next/Vercel.
- URLs ending in `.md` serve raw Markdown for source-level references.
- Extensionless URLs render curated Markdown with the richer human-readable UI.

`reader.html` is a shared renderer template, not a public navigation target. `docs:sync` uses it to generate `index.html` pages beside each raw Markdown file. The local docs server also uses the same template for extensionless paths, so local navigation can exercise the nicer rendered pages without duplicating Markdown content in React.

## Rendered Page Contract

Public docs navigation is path-based:

```text
https://spaces.cloudcompute.com/docs/product_overview
https://spaces.cloudcompute.com/docs/CONTEXT
https://spaces.cloudcompute.com/docs/development/libghostty-integration
```

These URLs render the docs page. They are generated from the curated manifest during `docs:sync`.

The deployed generated structure is:

```text
web/public/docs/
  index.html
  docs-manifest.json
  _renderer/
    index.html
  product_overview.md
  product_overview/
    index.html
  development/
    libghostty-integration.md
    libghostty-integration/
      index.html
```

The `_renderer` page is the middleware target for extensionless paths. The per-document `index.html` files keep the generated output inspectable and static-hosting friendly.

## Raw Markdown Contract

Any public docs URL ending in `.md` returns raw Markdown, not the rendered reader shell. Use these URLs for source-level references:

```text
https://spaces.cloudcompute.com/docs/product_overview.md
https://spaces.cloudcompute.com/docs/CONTEXT.md
https://spaces.cloudcompute.com/docs/development/libghostty-integration.md
```

Use the extensionless path when the page should render Markdown with the visual docs frame.

## Run Locally

From the repository root:

```bash
uv run --script docs/server.py
```

Then open:

```text
http://127.0.0.1:8088/docs/
```

You can choose a different port when needed:

```bash
uv run --script docs/server.py --port 8090
```

The server intentionally serves the repository root, not just `docs/`, so rendered pages can fetch root-level Markdown such as `README.md` and `CONTEXT.md`.

### Local AI Docs Ask

The Developer and Operator Index has a local-only ask path. It is available only when the docs are served over HTTP from `docs/server.py`; it cannot work from `file://` URLs.

- Typing in the top input live-filters the local docs index.
- Pressing Enter sends the query and the current visible matches to `POST /docs/api/ask`.
- The server shells out to Claude Code in non-interactive mode with read/search-only tools.
- The response is rendered above the results with citations and a copy button.

Default command shape:

```bash
claude --bare -p <prompt> \
  --output-format json \
  --json-schema <schema> \
  --append-system-prompt <docs prompt> \
  --allowedTools Read,Grep,Glob \
  --max-turns 4 \
  --max-budget-usd 0.25 \
  --no-session-persistence
```

Useful local environment overrides:

```bash
WORKSPACES_DOCS_ASK_CLAUDE_BIN=/path/to/claude
WORKSPACES_DOCS_ASK_MAX_TURNS=4
WORKSPACES_DOCS_ASK_MAX_BUDGET_USD=0.25
WORKSPACES_DOCS_ASK_TIMEOUT_SECONDS=120
```

This endpoint is intentionally not part of the public/Vercel docs contract.

## Link Conventions

Use extensionless paths for rendered docs links:

```html
<a href="/docs/product_overview">Product Overview</a>
<a href="/docs/CONTEXT">Vocabulary</a>
```

Direct links to existing HTML pages are fine:

```html
<a href="user-guide/">User Guide</a>
```

Inside rendered Markdown, local `.md` links are automatically rewritten to extensionless rendered paths.

## Reader Behavior

Rendered pages should stay focused on understanding the product and codebase first. Exact source details remain available, but they are not the main reading path.

- Concept chips are filters. Selecting a chip shows related published docs for that WorkSpaces domain topic.
- The reader shows only compact, friendly page-level metadata by default.
- The sidebar shows same-group docs first, then switches to concept-related docs when a chip is selected.
- Exact source remains available through the raw Markdown link instead of occupying the hero.
- A standalone `Last updated:` source line is lifted into metadata instead of repeated in the rendered body.

## Vocabulary Contract

Use [../CONTEXT.md](../CONTEXT.md) as the canonical language source for the native app. The docs site should prefer these terms:

- **WorkSpaces**
- **Repository**
- **Workspace**
- **Terminal Session**
- **Surface**
- **Repo Overview**
- **Web Source**
- **Detail Pane**

Avoid reusing **Spaces** for the native app. In this repository, **Spaces** refers to the separate web/chat dashboard context.

## Quality Checks

Before considering docs-site changes ready, run:

```bash
uv run --script scripts/docs-server-smoke.py
pnpm --dir web docs:sync
pnpm --dir web docs:check
pnpm --dir web test:e2e:docs-local
pnpm --dir web test:e2e:docs
node -e "for (const file of ['docs/index.html','docs/reader.html','docs/developer-operator-index.html']) { const fs=require('fs'); const html=fs.readFileSync(file,'utf8'); const scripts=[...html.matchAll(/<script>([\\s\\S]*?)<\\/script>/g)]; for (const script of scripts) new Function(script[1]); console.log(file, 'script ok'); }"
git -c core.whitespace=blank-at-eol,blank-at-eof,space-before-tab diff --check
```

Web CI also runs `docs:sync` and `docs:check` before lint, typecheck, tests, and build. Do not commit `web/public/docs`; it is generated by local dev, local build, and CI.

The fast smoke script starts an isolated local docs server, injects a fake Claude
Code binary, then verifies the operator index, local manifest, raw Markdown
paths, extensionless rendered paths, and `/docs/api/ask` response shape. Use
`--base-url http://127.0.0.1:<port>` to check an already-running server; add
`--ask` only when you intentionally want to exercise the real configured Claude
Code binary.

To run the same server/API smoke against the real Claude Code binary:

```bash
uv run --script scripts/docs-server-smoke.py --real-claude
```

This intentionally fails when Claude Code is not logged in, when the local
Claude CLI cannot use non-interactive mode, or when the docs answer exceeds the
local timeout/budget.

For answer-quality regression checks, run the focused eval harness:

```bash
uv run --script scripts/docs-ask-eval.py
uv run --script scripts/docs-ask-eval.py --real-claude
uv run --script scripts/docs-ask-eval.py --base-url http://127.0.0.1:8098
```

The default eval starts an isolated server with a fake Claude Code binary and
checks the endpoint contract. `--real-claude` or `--base-url` exercises the real
local ask path and reports citation, terminology, and source-coverage failures.

Agents can query the local docs server through the repo-local skill:

```bash
uv run --script .agents/skills/workspaces-docs-ask/scripts/query-docs.py "Where is the Lume daemon reliability runbook?"
```

The Playwright docs checks are split by hosting mode:

- `test:e2e:docs-local` starts `docs/server.py` directly and exercises the local-only operator index, autocomplete, AI answer box, citations, and copy flow with a fake Claude Code binary.
- `test:e2e:docs` runs against the `web/` app and verifies the public/static docs route behavior.

With the server running, spot-check:

```bash
curl -I http://127.0.0.1:8088/docs/
curl -I http://127.0.0.1:8088/docs/product_overview
curl -I http://127.0.0.1:8088/docs/product_overview.md
curl -I http://127.0.0.1:8088/docs/CONTEXT
curl -I http://127.0.0.1:8088/favicon.ico
```

Expected results:

- `/docs/` returns `200`
- `/docs/product_overview` returns rendered HTML
- `/docs/product_overview.md` returns raw Markdown
- `/docs/CONTEXT` renders root `CONTEXT.md`
- `/` redirects to `/docs/`
- `/favicon.ico` redirects to the docs favicon
