//
//  WebSourceDetailView.swift
//  WorkspaceManager
//
//  Detail pane for URL source browsing, rendered through the Surface seam: the pane is a
//  single-tile SurfaceStore domain whose tile is rebound across source switches.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

struct WebSourceDetailView: View {
    let source: WebSource
    let tileID: TileID
    let surfaceStore: SurfaceStore
    /// Fired (async, post-update) when the tile's surface view mounts. Dev automation observes
    /// this to gate on "web renders through the seam".
    var onSurfaceMounted: ((WebSource) -> Void)?

    @State private var lastBlockedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if source.baseURL != nil {
                WebSurfacePaneView(
                    tileID: tileID,
                    source: source,
                    surfaceStore: surfaceStore,
                    onBlockedNavigation: { blockedURL in
                        lastBlockedURL = blockedURL
                    },
                    onSurfaceMounted: onSurfaceMounted
                )
                // Source switches rebind the tile to a new surface (the store's identity guard
                // evicts the old one), so the mounted NSView changes — force a fresh mount rather
                // than asking updateNSView to swap views.
                .id(source.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Invalid URL Source",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This source has an invalid URL. Remove and add it again.")
                )
            }

            if let lastBlockedURL {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Opened outside allowed domain: \(lastBlockedURL.host ?? lastBlockedURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .navigationTitle(source.name)
        .onChange(of: source.id) { _, _ in
            lastBlockedURL = nil
        }
        // Eviction is NOT tied to this view's lifecycle: `onDisappear` is unordered against the
        // replacement view's mount, so a late fire could evict a freshly re-mounted surface and
        // leave its visible WKWebView without a navigation policy after the deferred release.
        // ContentView empties the domain from the selection transition instead (ordered).
    }
}

/// Mounts the web tile's surface view from the seam. `makeContentView` is store-owned and
/// reused across updates; the enclosing `.id(source.id)` guarantees a given representable
/// instance only ever sees one (tile, source) binding.
private struct WebSurfacePaneView: NSViewRepresentable {
    let tileID: TileID
    let source: WebSource
    let surfaceStore: SurfaceStore
    var onBlockedNavigation: ((URL) -> Void)?
    var onSurfaceMounted: ((WebSource) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = mountedView()
        if let onSurfaceMounted {
            let source = source
            // Defer past the SwiftUI update so observers can publish freely.
            DispatchQueue.main.async { onSurfaceMounted(source) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-resolving on update refreshes the blocked-navigation hook on the live policy,
        // matching the legacy direct-path behavior.
        _ = mountedView()
    }

    private func mountedView() -> NSView {
        surfaceStore
            .webSurface(for: tileID, source: source, onBlockedNavigation: onBlockedNavigation)
            .makeContentView()
    }
}
