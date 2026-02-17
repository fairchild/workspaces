# Landing Page

**Status**: backlog
**Priority**: after polish phase, before or alongside public launch

## Purpose

Public-facing page for the Workspaces project. Gives potential users and forkers a quick visual overview before they hit the GitHub repo.

## Hosting

GitHub Pages or Cloudflare Pages — whichever is simpler. Single static page is fine.

## Content Outline

1. **Hero**: Screenshot/screencast of the app in use, tagline ("Terminal-first workspace manager for AI coding")
2. **Value prop**: 3-4 bullet points — what it does, why it exists
3. **Download link**: Direct to GitHub Releases (latest DMG)
4. **Philosophy blurb**: Agent-first codebase, modern baseline, fork-friendly, no backwards-compat baggage
5. **Companion link**: Link to [dotclaude](https://github.com/fairchild/dotclaude) — the two repos together demonstrate a full AI-augmented dev setup
6. **Fork CTA**: "Fork & make it yours" with link to repo

## Tech

- Static site — single `index.html` or lightweight framework (Astro, 11ty)
- Keep it minimal: one page, no build pipeline if possible
- Dark theme consistent with app aesthetic

## Design Reference

- `docs/branding.md` for color palette, icon assets, and design principles
- Color palette: charcoal `#1e1e2a`, mint green `#4ade80`, subtle gray `#3a3a4a`
- Use the app icon (`icon-concepts/icon-master-1024.png`) as favicon and hero element

## Open Questions

- Screenshot vs. screencast? (screencast shows terminal in action but adds complexity)
- Custom domain or `fairchild.github.io/workspaces`?
