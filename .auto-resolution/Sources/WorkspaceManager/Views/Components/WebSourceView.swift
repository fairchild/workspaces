//
//  WebSourceView.swift
//  WorkspaceManager
//
//  SwiftUI wrapper for an embedded WKWebView surface.
//

import SwiftUI
import WebKit
import WorkspaceManagerCore

struct WebSourceView: NSViewRepresentable {
    let source: WebSource
    @ObservedObject var surfaceStore: WebSurfaceStore
    var onBlockedNavigation: ((URL) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        surfaceStore.ensureSurface(
            for: source,
            onBlockedNavigation: onBlockedNavigation
        )
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = nsView
        _ = context
        _ = surfaceStore.ensureSurface(
            for: source,
            onBlockedNavigation: onBlockedNavigation
        )
    }
}
