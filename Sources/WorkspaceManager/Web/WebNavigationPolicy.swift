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
    private(set) var activeAllowedHost: String
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
        let normalizedAllowedHost = allowedHost.lowercased()
        self.allowedHost = normalizedAllowedHost
        self.activeAllowedHost = normalizedAllowedHost
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

        if adoptAllowedHostForRelatedNavigationIfNeeded(
            candidateURL: url,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame
        ) {
            decisionHandler(.allow)
            return
        }

        handleBlockedNavigation(
            url: url,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            navigationType: navigationAction.navigationType
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
            isAllowedFor: activeAllowedHost,
            allowsSubdomains: allowsSubdomains
        )
    }

    @discardableResult
    func adoptAllowedHostForRelatedNavigationIfNeeded(
        candidateURL: URL,
        targetFrameIsMainFrame: Bool?
    ) -> Bool {
        guard targetFrameIsMainFrame != false else { return false }
        guard let candidateHost = candidateURL.host?.lowercased(), !candidateHost.isEmpty else {
            return false
        }
        guard shouldAdoptHostForRelatedNavigation(candidateHost: candidateHost) else {
            return false
        }

        if candidateHost != activeAllowedHost {
            NSLog(
                "[WebView] Adopting related host %@ for allowed host %@",
                candidateHost,
                activeAllowedHost
            )
        }
        activeAllowedHost = candidateHost
        return true
    }

    private func shouldAdoptHostForRelatedNavigation(candidateHost: String) -> Bool {
        if WebSourceValidation.host(
            candidateHost,
            isAllowedFor: activeAllowedHost,
            allowsSubdomains: allowsSubdomains
        ) {
            return true
        }

        return allowsSubdomains && activeAllowedHost.hasSuffix(".\(candidateHost)")
    }

    func shouldOpenOutsideAppForBlockedNavigation(
        targetFrameIsMainFrame: Bool?,
        navigationType: WKNavigationType
    ) -> Bool {
        // Ignore blocked iframe/subframe hops; only top-level/new-window attempts
        // should open externally.
        guard targetFrameIsMainFrame != false else { return false }

        switch navigationType {
        case .linkActivated, .formSubmitted:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func handleBlockedNavigation(
        url: URL,
        targetFrameIsMainFrame: Bool?,
        navigationType: WKNavigationType
    ) -> Bool {
        guard
            shouldOpenOutsideAppForBlockedNavigation(
                targetFrameIsMainFrame: targetFrameIsMainFrame,
                navigationType: navigationType
            )
        else {
            return false
        }

        openURL(url)
        onBlockedNavigation?(url)
        return true
    }
}
