import AppKit
import WebKit
import WorkspaceManagerCore

/// `Surface` conformer backing a web tile with a `WKWebView` managed by a `WebSurfaceStore`.
///
/// Carries none of the agent-domain coupling a `TerminalSurface` does — no registry, OSC, command
/// status, or local state — which is the asymmetry that proves the seam is genuinely generic.
///
/// Store ownership is **shared per source** (the Phase 6 decision from the PR #633 review): the
/// owning `SurfaceStore` keys `WebSurfaceStore`s by `WebSource.id` and injects them here, so the
/// `WKWebView` outlives any one surface binding. `tearDown` is correspondingly **deferred**
/// (`scheduleInactiveRelease`): an evicted web tile keeps its page alive through the release
/// grace window, so flipping away and back does not reload — the web half of the per-conformer
/// eviction policy (terminal frees immediately; web releases lazily).
@MainActor
final class WebSurface: Surface {
    let kind: SurfaceKind = .web
    let tileID: TileID
    let source: WebSource

    private let surfaceStore: WebSurfaceStore
    var onBlockedNavigation: ((URL) -> Void)?

    init(
        tileID: TileID,
        source: WebSource,
        surfaceStore: WebSurfaceStore? = nil,
        onBlockedNavigation: ((URL) -> Void)? = nil
    ) {
        self.tileID = tileID
        self.source = source
        self.surfaceStore = surfaceStore ?? WebSurfaceStore()
        self.onBlockedNavigation = onBlockedNavigation
    }

    func makeContentView() -> NSView {
        surfaceStore.ensureSurface(for: source, onBlockedNavigation: onBlockedNavigation)
    }

    /// The live `WKWebView`, instantiated on demand. Backs source-level actions that need the
    /// actual page state — reload, open-current-URL-in-browser.
    var webView: WKWebView {
        surfaceStore.ensureSurface(for: source, onBlockedNavigation: onBlockedNavigation)
    }

    var displayTitle: String {
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        return source.allowedHost.isEmpty ? "Web" : source.allowedHost
    }

    func focus() {
        // No-op until the tile has mounted its web view: focusing should not be what instantiates a
        // WKWebView and starts a page load (that is `makeContentView`'s job). Mirrors `resignFocus`.
        guard surfaceStore.hasActiveSurface else { return }
        let webView = surfaceStore.ensureSurface(for: source, onBlockedNavigation: onBlockedNavigation)
        webView.window?.makeFirstResponder(webView)
    }

    func resignFocus() {
        guard surfaceStore.hasActiveSurface else { return }
        let webView = surfaceStore.ensureSurface(for: source, onBlockedNavigation: onBlockedNavigation)
        if let window = webView.window, window.firstResponder === webView {
            window.makeFirstResponder(nil)
        }
    }

    func requestClose() {
        // Web has no close-confirmation gate (unlike the terminal), so user-intent close and
        // store eviction coincide — both defer to the shared store's release grace window.
        tearDown()
    }

    func tearDown() {
        surfaceStore.scheduleInactiveRelease()
    }
}
