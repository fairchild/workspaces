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
pnpm --dir web docs:sync
pnpm --dir web docs:check
node -e "for (const file of ['docs/index.html','docs/reader.html']) { const fs=require('fs'); const html=fs.readFileSync(file,'utf8'); const scripts=[...html.matchAll(/<script>([\\s\\S]*?)<\\/script>/g)]; for (const script of scripts) new Function(script[1]); console.log(file, 'script ok'); }"
git diff --check
```

Web CI also runs `docs:sync` and `docs:check` before lint, typecheck, tests, and build. Do not commit `web/public/docs`; it is generated by local dev, local build, and CI.

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
