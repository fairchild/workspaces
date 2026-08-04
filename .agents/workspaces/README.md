# .agents/workspaces — Repo Landing Override

> **Not currently wired up.** Commit `a7569b39` ("refine main window navigation and
> simplify sidebar chrome") replaced this WKWebView-based override with a native SwiftUI
> `RepoLandingView`; there is no WebKit bridge or `.agents/workspaces/index.html`
> override-loading path in the app anymore. This directory describes the prior design.

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

The app pushed live workspace data to `window.RepoLanding.onData(data)` and listened for actions via `window.webkit.messageHandlers.repoLanding.postMessage({ action, ... })`, per the design this directory describes. Current `RepoLandingView.swift` is native SwiftUI and has no such bridge.
