import AppKit
import WebKit
import WorkspaceManagerCore

/// `Surface` conformer backing a web tile with a `WKWebView` managed by `WebSurfaceStore`.
///
/// Carries none of the agent-domain coupling a `TerminalSurface` does — no registry, OSC, command
/// status, or local state — which is the asymmetry that proves the seam is genuinely generic.
/// `tearDown` releases the web view immediately (`releaseInactiveSurface`). Because each `WebSurface`
/// privately owns its `WebSurfaceStore`, an evicted web tile reloads when reopened; whether to keep a
/// shared store-per-source (reuse the view, defer release) is an explicit Phase 6 decision (PR #633
/// review), not wired here.
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
        // unconditional teardown coincide. Issuing the tree `.close` for a web tile lands with
        // main-content unification (Phase 6); here we simply release the view.
        tearDown()
    }

    func tearDown() {
        surfaceStore.releaseInactiveSurface()
    }
}
