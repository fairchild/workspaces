//
//  WebSurfaceStore.swift
//  WorkspaceManager
//
//  Lazy lifecycle manager for the embedded web surface.
//

import Foundation
import WebKit
import WorkspaceManagerCore

@MainActor
final class WebSurfaceStore: ObservableObject {
    private struct ActiveSurface {
        let webView: WKWebView
        let policy: WebNavigationPolicy
        let sourceID: UUID
    }

    @Published private(set) var hasInstantiatedSurface = false

    private var activeSurface: ActiveSurface?
    private var scheduledRelease: DispatchWorkItem?
    private let autoLoadInitialURL: Bool

    init(autoLoadInitialURL: Bool = true) {
        self.autoLoadInitialURL = autoLoadInitialURL
    }

    var hasActiveSurface: Bool {
        activeSurface != nil
    }

    /// Read-only snapshot of the live `WKWebView`'s navigation state for the
    /// Automation API's browser-read list. Returns `nil` when no surface is
    /// instantiated — the caller must not fabricate URL/title for a released view.
    /// Does not instantiate a surface.
    var liveState: WebSurfaceLiveState? {
        guard let webView = activeSurface?.webView else { return nil }
        return WebSurfaceLiveState(
            url: webView.url?.absoluteString,
            title: webView.title,
            isLoading: webView.isLoading
        )
    }

    /// The live `WKWebView` for the Automation API's browser-read snapshot, or `nil`
    /// when no surface is instantiated. A non-creating peek (like `liveState`): it never
    /// instantiates a view, so snapshotting a released surface fails closed rather than
    /// spinning up a hidden page.
    var liveWebView: WKWebView? {
        activeSurface?.webView
    }

    func ensureSurface(
        for source: WebSource,
        onBlockedNavigation: ((URL) -> Void)? = nil
    ) -> WKWebView {
        cancelPendingRelease()

        if let activeSurface, activeSurface.sourceID == source.id {
            activeSurface.policy.onBlockedNavigation = onBlockedNavigation
            return activeSurface.webView
        }

        let switchedSource = activeSurface?.sourceID != source.id

        let webView: WKWebView
        if let existing = activeSurface?.webView {
            webView = existing
        } else {
            PerformanceSignposts.beginWebViewInitializationIfNeeded()
            webView = makeWebView()
            hasInstantiatedSurface = true
            PerformanceSignposts.endWebViewInitializationIfNeeded(outcome: "created")
        }

        let policy = WebNavigationPolicy(
            allowedHost: source.allowedHost,
            additionalAllowedDomains: source.additionalAllowedDomains,
            allowsSubdomains: true,
            onBlockedNavigation: onBlockedNavigation
        )
        webView.navigationDelegate = policy
        activeSurface = ActiveSurface(
            webView: webView,
            policy: policy,
            sourceID: source.id
        )

        if autoLoadInitialURL, switchedSource || webView.url == nil {
            loadInitialURL(for: source, in: webView)
        }

        return webView
    }

    func scheduleInactiveRelease(after seconds: TimeInterval = 30) {
        cancelPendingRelease()

        guard activeSurface != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.releaseInactiveSurface()
            }
        }
        scheduledRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancelPendingRelease() {
        scheduledRelease?.cancel()
        scheduledRelease = nil
    }

    func releaseInactiveSurface() {
        cancelPendingRelease()
        guard let activeSurface else { return }
        activeSurface.webView.stopLoading()
        activeSurface.webView.navigationDelegate = nil
        self.activeSurface = nil
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    private func loadInitialURL(for source: WebSource, in webView: WKWebView) {
        guard let url = source.baseURL else { return }
        PerformanceSignposts.beginWebFirstLoadIfNeeded(sourceID: source.id)
        webView.load(URLRequest(url: url))
    }
}
