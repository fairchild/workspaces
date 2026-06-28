//
//  EditorSurfaceView.swift
//  WorkspaceManager
//
//  SwiftUI wrapper for the store-owned WKWebView that hosts the CodeMirror editor.
//

import SwiftUI
import WebKit

struct EditorSurfaceView: NSViewRepresentable {
    @ObservedObject var store: EditorSurfaceStore

    func makeNSView(context: Context) -> WKWebView {
        store.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        _ = nsView
        _ = context
    }
}
