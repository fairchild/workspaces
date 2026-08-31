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
https://spaces.cloudcompute.com/docs/GLOSSARY
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
https://spaces.cloudcompute.com/docs/GLOSSARY.md
https://spaces.cloudcompute.com/docs/development/libghostty-integration.md
```

Use the extensionless path when the page should render Markdown with the visual docs frame.

## Run Locally

From the repository root:

```bash
mise run docs:serve
```

Then open:

```text
http://127.0.0.1:8088/docs/
```

You can choose a different port when needed:

```bash
mise run docs:serve -- --port 8090
```

The server intentionally serves the repository root, not just `docs/`, so rendered pages can fetch root-level Markdown such as `README.md` and `GLOSSARY.md`.

### Local Search API

The Developer and Operator Index has a local-only search path. It is available only when the docs are served over HTTP from `docs/server.py`; it cannot work from `file://` URLs.

- Typing in the top input live-filters the local docs index.
- Live filtering uses `GET /docs/api/search?q=&group=&topic=&type=&limit=`, which returns the canonical local ranked result set.
- Pressing Enter keeps the same filtered result set visible; the page remains search-only.
- The search endpoint is intentionally local-only and is not part of the public/Vercel docs contract.

Example:

```text
GET /docs/api/search?q=lum%20failng&group=&topic=&type=&limit=12
```

Response shape:

```json
{
  "query": "lum failng",
  "total": 3,
  "results": [
    {
      "title": "Lume Integration",
      "url": "/docs/development/lume-integration",
      "source": "docs/development/lume-integration.md",
      "dest": "development/lume-integration.md",
      "snippet": "Daemon reliability...",
      "topics": ["lume", "provider"],
      "group": "Development",
      "type": "Runbook"
    }
  ]
}
```

The operator index shell lives in `docs/developer-operator-index.html`; its page-specific behavior and styling live in `docs/assets/operator-index.js` and `docs/assets/operator-index.css`.

## Link Conventions

Use extensionless paths for rendered docs links:

```html
<a href="/docs/product_overview">Product Overview</a>
<a href="/docs/GLOSSARY">Vocabulary</a>
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

Use [../GLOSSARY.md](../GLOSSARY.md) as the canonical language source for the native app. The docs site should prefer these terms:

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
python3 -m py_compile docs/server.py scripts/docs_catalog.py scripts/docs-server-smoke.py
node --check docs/assets/operator-index.js
git -c core.whitespace=blank-at-eol,blank-at-eof,space-before-tab diff --check
```

Web CI also runs `docs:sync` and `docs:check` before lint, typecheck, tests, and build. Do not commit `web/public/docs`; it is generated by local dev, local build, and CI.

The fast smoke script starts an isolated local docs server, then verifies the
operator index, local manifest, raw Markdown paths, extensionless rendered
paths, and `/docs/api/search`. Use `--base-url http://127.0.0.1:<port>` to check
an already-running server.

The Playwright docs checks are split by hosting mode:

- `test:e2e:docs-local` starts `docs/server.py` directly and exercises the local-only operator index, autocomplete, search endpoint, and collapsible HUD panels.
- `test:e2e:docs` runs against the `web/` app and verifies the public/static docs route behavior.

With the server running, spot-check:

```bash
curl -I http://127.0.0.1:8088/docs/
curl -I http://127.0.0.1:8088/docs/product_overview
curl -I http://127.0.0.1:8088/docs/product_overview.md
curl -I http://127.0.0.1:8088/docs/GLOSSARY
curl -I http://127.0.0.1:8088/favicon.ico
```

Expected results:

- `/docs/` returns `200`
- `/docs/product_overview` returns rendered HTML
- `/docs/product_overview.md` returns raw Markdown
- `/docs/GLOSSARY` renders root `GLOSSARY.md`
- `/` redirects to `/docs/`
- `/favicon.ico` redirects to the docs favicon
