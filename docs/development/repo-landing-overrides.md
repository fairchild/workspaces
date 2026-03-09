# Repo Landing Page Overrides

When you click a repository in the sidebar, Workspaces shows a **landing page** with an overview of all workspaces under that repo. By default this is a native SwiftUI grid. You can replace it with a custom HTML page by placing an `index.html` in the `.agents/workspaces/` directory.

## Resolution Order

The app checks for a web override at two locations, first match wins:

```
1. <repo>/.agents/workspaces/index.html   (repo-local override)
2. ~/.agents/workspaces/index.html         (user-global override)
3. (none) → native SwiftUI grid            (built-in default)
```

If neither file exists, the native grid renders. There is no bundled HTML default.

## Creating an Override

Create `.agents/workspaces/index.html` in your repo or home directory. The HTML is loaded via `WKWebView.loadFileURL`, so it has read access to sibling files (CSS, JS, images) in the same directory. No server required.

Minimal structure:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div id="app"></div>
    <script src="app.js"></script>
</body>
</html>
```

## Bridge Contract

Data flows bidirectionally between Swift and JavaScript.

### Swift → JS (data push)

The app calls `window.RepoLanding.onData(data)` whenever workspace state changes. Your JS must expose this function:

```js
window.RepoLanding = {
    onData: function(data) { /* render UI */ }
};
```

The `data` payload:

```ts
{
    repo: {
        name: string,
        localPath: string,
        remoteURL: string | null
    },
    workspaces: [{
        id: string,           // UUID
        name: string,
        branch: string | null,
        path: string,
        status: "active" | "stopped" | "archived",
        lastAccessedAt: number, // Unix timestamp (seconds)
        isAgentRunning: boolean,
        agentName: string | null,
        processes: [{
            displayName: string,
            isKnownAgent: boolean
        }]
    }]
}
```

### JS → Swift (actions)

Send messages via the webkit message handler:

```js
window.webkit.messageHandlers.repoLanding.postMessage({
    action: "selectWorkspace",
    id: "workspace-uuid"
});
```

Available actions:

| Action | Extra fields | Effect |
|--------|-------------|--------|
| `ready` | — | Signals JS is initialized; triggers initial data push |
| `selectWorkspace` | `id` | Opens the workspace terminal |
| `createWorkspace` | — | Opens the new workspace sheet |
| `openTerminal` | — | Opens a terminal at the repo root |
| `archiveWorkspace` | `id` | Archives the workspace (handles remote backends) |
| `revealInFinder` | `id` | Reveals workspace directory in Finder |

### Readiness handshake

The bridge handles a race condition: JS may be ready before Swift has wired its callbacks. The sequence is:

1. Web view loads and JS calls `bridge("ready")`
2. If Swift hasn't wired callbacks yet, the bridge queues the ready signal
3. Once Swift configures the bridge, it pushes data immediately
4. If JS was already ready, data renders; otherwise it's queued until ready

## Standalone Development

For developing the HTML outside the app, detect the missing webkit handler and render with mock data:

```js
if (!window.webkit?.messageHandlers?.repoLanding) {
    render({ repo: { name: "my-repo", ... }, workspaces: [...] });
} else {
    bridge("ready");
}
```

Open `index.html` directly in a browser to iterate on styling without rebuilding the app.

## Implementation Files

| File | Role |
|------|------|
| `Sources/WorkspaceManager/Views/MainWindow/RepoLandingView.swift` | Resolution logic + bridge wiring |
| `Sources/WorkspaceManager/Web/RepoLandingBridge.swift` | WKScriptMessageHandler + data encoding |
| `Sources/WorkspaceManager/Web/RepoLandingWebView.swift` | NSViewRepresentable WKWebView wrapper |
