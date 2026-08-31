// The node's web-next surface in a WKWebView: load the sign-in URL once,
// the cookie persists for the session, and a rejected token is reported up
// rather than silently parking the user on a sign-in page.
import SwiftUI
import WebKit

struct SessionsWebView: UIViewRepresentable {
    let node: Node
    @Binding var reloadToken: Int
    /// Called when a main-frame navigation on this node lands on its sign-in
    /// page with a 200 — in local mode that means only one thing: this
    /// device's token is no longer accepted. A valid token always redirects
    /// away. Status and origin are both checked so a Host-gate refusal or an
    /// off-node page can't masquerade as a rejected token (codex review).
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
        context.coordinator.nodeHost = node.host
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

    func makeCoordinator() -> Coordinator {
        Coordinator(nodeHost: node.host, onTokenRejected: onTokenRejected)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastReloadToken = 0
        var lastNode: Node?
        var nodeHost: String
        var onTokenRejected: () -> Void

        init(nodeHost: String, onTokenRejected: @escaping () -> Void) {
            self.nodeHost = nodeHost
            self.onTokenRejected = onTokenRejected
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            defer { decisionHandler(.allow) }
            guard navigationResponse.isForMainFrame,
                let http = navigationResponse.response as? HTTPURLResponse,
                http.statusCode == 200,
                let url = http.url,
                url.host == nodeHost,
                url.path == "/sign-in"
            else { return }
            onTokenRejected()
        }
    }
}
