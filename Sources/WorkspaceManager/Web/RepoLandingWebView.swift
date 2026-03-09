//
//  RepoLandingWebView.swift
//  WorkspaceManager
//
//  NSViewRepresentable that loads a local HTML repo landing page in WKWebView.
//

import SwiftUI
import WebKit

struct RepoLandingWebView: NSViewRepresentable {
    let indexURL: URL
    let bridge: RepoLandingBridge

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: RepoLandingBridge.handlerName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        bridge.attach(webView)
        webView.loadFileURL(
            indexURL,
            allowingReadAccessTo: indexURL.deletingLastPathComponent()
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: RepoLandingBridge.handlerName
        )
    }
}
