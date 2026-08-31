// The node's web-next surface in a WKWebView: load the sign-in URL once,
// the cookie persists in the default website data store, and every later
// launch lands signed in. Native chrome stays thin until the bearer-auth
// contract (#1455) gives the app first-class data to render.
import SwiftUI
import WebKit

struct SessionsWebView: UIViewRepresentable {
    let node: Node
    @Binding var reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.load(URLRequest(url: node.signInURL()))
        context.coordinator.lastReloadToken = reloadToken
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: node.signInURL()))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastReloadToken = 0
    }
}
