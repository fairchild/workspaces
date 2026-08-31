// The node's web-next surface in a WKWebView: load the sign-in URL once,
// the cookie persists for the session, and a rejected token is reported up
// rather than silently parking the user on a sign-in page.
import SwiftUI
import WebKit

struct SessionsWebView: UIViewRepresentable {
    let node: Node
    @Binding var reloadToken: Int
    /// Called when a navigation settles on the node's sign-in page, which in
    /// local mode means only one thing: this device's token is no longer
    /// accepted (rotated on the Mac). A valid token always redirects away.
    let onTokenRejected: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Ephemeral on purpose: the durable credential is the Keychain token,
        // which re-establishes the cookie on every launch — so unpairing
        // leaves no WebKit residue behind (codex review).
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: node.signInURL()))
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastNode = node
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Refresh the callback each update so it never closes over stale state.
        context.coordinator.onTokenRejected = onTokenRejected
        if context.coordinator.lastNode != node {
            context.coordinator.lastNode = node
            webView.load(URLRequest(url: node.signInURL()))
            return
        }
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            // Reload the current page; replaying the token-bearing sign-in
            // URL here would be needless credential exposure (codex review).
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTokenRejected: onTokenRejected) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastReloadToken = 0
        var lastNode: Node?
        var onTokenRejected: () -> Void

        init(onTokenRejected: @escaping () -> Void) {
            self.onTokenRejected = onTokenRejected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.path == "/sign-in" else { return }
            onTokenRejected()
        }
    }
}
