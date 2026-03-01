//
//  WebNavigationPolicy.swift
//  WorkspaceManager
//
//  Domain-restricted navigation policy for embedded URL sources.
//

import AppKit
import Foundation
import WebKit
import WorkspaceManagerCore

@MainActor
final class WebNavigationPolicy: NSObject, WKNavigationDelegate {
    let allowedHost: String
    let allowsSubdomains: Bool
    private let openURL: (URL) -> Void
    var onBlockedNavigation: ((URL) -> Void)?

    init(
        allowedHost: String,
        allowsSubdomains: Bool = true,
        openURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        },
        onBlockedNavigation: ((URL) -> Void)? = nil
    ) {
        self.allowedHost = allowedHost
        self.allowsSubdomains = allowsSubdomains
        self.openURL = openURL
        self.onBlockedNavigation = onBlockedNavigation
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if shouldAllow(url: url) {
            decisionHandler(.allow)
            return
        }

        handleBlockedNavigation(
            url: url,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame
        )
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PerformanceSignposts.endWebFirstLoadIfNeeded(outcome: "finished")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        PerformanceSignposts.endWebFirstLoadIfNeeded(outcome: "failed")
        NSLog("[WebView] Navigation failed: %@", error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        PerformanceSignposts.endWebFirstLoadIfNeeded(outcome: "failed_provisional")
        NSLog("[WebView] Provisional navigation failed: %@", error.localizedDescription)
    }

    func shouldAllow(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "about":
            return true
        case "http", "https":
            break
        default:
            return false
        }

        guard let host = url.host else {
            return false
        }

        return WebSourceValidation.host(
            host,
            isAllowedFor: allowedHost,
            allowsSubdomains: allowsSubdomains
        )
    }

    func shouldOpenOutsideAppForBlockedNavigation(targetFrameIsMainFrame: Bool?) -> Bool {
        // Ignore blocked iframe/subframe hops; only top-level/new-window attempts
        // should open externally.
        targetFrameIsMainFrame != false
    }

    @discardableResult
    func handleBlockedNavigation(
        url: URL,
        targetFrameIsMainFrame: Bool?
    ) -> Bool {
        guard
            shouldOpenOutsideAppForBlockedNavigation(
                targetFrameIsMainFrame: targetFrameIsMainFrame
            )
        else {
            return false
        }

        openURL(url)
        onBlockedNavigation?(url)
        return true
    }
}
