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
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WebNavigationPolicy")

@MainActor
final class WebNavigationPolicy: NSObject, WKNavigationDelegate {
    let allowedHost: String
    let additionalAllowedDomains: [String]
    private(set) var activeAllowedHost: String
    let allowsSubdomains: Bool
    /// When set, navigation must match this port as well as an allowed host.
    /// Cookies aren't port-scoped, so a host-only allowlist would let a
    /// token-bearing loopback surface send its session cookie to any other local
    /// service; pinning the port closes that. `nil` keeps host-only matching for
    /// callers that don't need it.
    let allowedPort: Int?
    private let openURL: (URL) -> Void
    var onBlockedNavigation: ((URL) -> Void)?

    init(
        allowedHost: String,
        additionalAllowedDomains: [String] = [],
        allowsSubdomains: Bool = true,
        allowedPort: Int? = nil,
        openURL: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        },
        onBlockedNavigation: ((URL) -> Void)? = nil
    ) {
        let normalizedAllowedHost = allowedHost.lowercased()
        self.allowedHost = normalizedAllowedHost
        self.additionalAllowedDomains = additionalAllowedDomains.map { $0.lowercased() }
        self.activeAllowedHost = normalizedAllowedHost
        self.allowsSubdomains = allowsSubdomains
        self.allowedPort = allowedPort
        self.openURL = openURL
        self.onBlockedNavigation = onBlockedNavigation
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
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
        log.error("[WebView] Navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        PerformanceSignposts.endWebFirstLoadIfNeeded(outcome: "failed_provisional")
        log.error("[WebView] Provisional navigation failed: \(error.localizedDescription, privacy: .public)")
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

        // Port gate (applies to primary host and additional domains alike): a
        // token-bearing surface must not navigate to a different port on an
        // otherwise-allowed host.
        if let allowedPort, url.port != allowedPort {
            return false
        }

        if WebSourceValidation.host(
            host,
            isAllowedFor: activeAllowedHost,
            allowsSubdomains: allowsSubdomains
        ) {
            return true
        }

        return additionalAllowedDomains.contains {
            WebSourceValidation.host(host, matchesAllowlistDomain: $0)
        }
    }

    @discardableResult
    func adoptAllowedHostForRelatedNavigationIfNeeded(
        candidateURL: URL,
        targetFrameIsMainFrame: Bool?
    ) -> Bool {
        guard targetFrameIsMainFrame != false else { return false }
        // Never adopt across the pinned port, even for an already-allowed host.
        if let allowedPort, candidateURL.port != allowedPort {
            return false
        }
        guard let candidateHost = candidateURL.host?.lowercased(), !candidateHost.isEmpty else {
            return false
        }
        guard shouldAdoptHostForRelatedNavigation(candidateHost: candidateHost) else {
            return false
        }

        if candidateHost != activeAllowedHost {
            log.info(
                "[WebView] Adopting related host \(candidateHost, privacy: .public) for allowed host \(self.activeAllowedHost, privacy: .public)"
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
