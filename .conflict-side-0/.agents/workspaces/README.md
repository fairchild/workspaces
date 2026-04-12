# .agents/workspaces — Repo Landing Override

This directory replaces the native SwiftUI landing page with a custom HTML dashboard when you click this repo in the sidebar.

## How it works

Workspaces checks for `.agents/workspaces/index.html` at two levels:

1. **Repo-local** (this directory) — override for just this repo
2. **`~/.agents/workspaces/`** — global override for all repos

If neither exists, the built-in SwiftUI grid renders instead.

## Files

| File | Purpose |
|------|---------|
| `index.html` | Entry point loaded by WKWebView |
| `style.css` | Apple-flavored dark/light theme |
| `app.js` | Renders workspace cards, bridges JS ↔ Swift |

## Developing

Open `index.html` in a browser — the JS detects the missing webkit handler and renders with mock data, so you can iterate on styling without rebuilding the app.

## Bridge

The app pushes live workspace data to `window.RepoLanding.onData(data)` and listens for actions via `window.webkit.messageHandlers.repoLanding.postMessage({ action, ... })`. See [docs/development/repo-landing-overrides.md](../../docs/development/repo-landing-overrides.md) for the full contract.
