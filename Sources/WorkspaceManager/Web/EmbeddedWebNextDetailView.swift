//
//  EmbeddedWebNextDetailView.swift
//  WorkspaceManager
//
//  The in-app pane for the embedded local-mode web-next experience. On
//  activation it lazily starts the `WebNextServerService`, shows a status pane
//  while the server comes up (or fails), then mounts a WKWebView navigated to
//  the token-bearing sign-in URL (redirecting to `/` for a plain open, or to
//  `/new?repo=<owner>/<name>` for a repo-bound New Web Session). Navigation is
//  locked to the loopback origin; external links open in the default browser.
//
//  This deliberately does not reuse `WebSurfaceStore`, which is keyed to a
//  persisted `WebSource`: the sign-in URL carries a bearer token that must never
//  land in a persisted model, so the surface stays ephemeral and view-local.
//

import AppKit
import SwiftUI
import WebKit
import WorkspaceManagerCore

/// Drives one activation of the embedded surface: start the server, resolve the
/// signed-in URL, and expose a coarse phase the view renders. Recreated per
/// activation (the detail view is `.id`-keyed), so a New Web Session always
/// re-navigates rather than reusing a stale page.
@MainActor
final class EmbeddedWebNextModel: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting

    private let server: any WebNextServerServiceProtocol

    init(server: any WebNextServerServiceProtocol) {
        self.server = server
    }

    func activate(redirect: String?) async {
        phase = .connecting
        // `start()` returns once the server is ready, has failed, or timed out;
        // it is a no-op when already ready, so re-activation is cheap.
        await server.start()

        switch await server.state {
        case .ready:
            if let url = await server.signInURL(redirect: redirect) {
                phase = .ready(url)
            } else {
                phase = .failed(
                    "web-next is running but the sign-in token is not available yet. Try again in a moment."
                )
            }
        case .failed(let reason):
            phase = .failed(reason)
        case .idle, .starting:
            phase = .failed("web-next did not reach a ready state.")
        }
    }
}

struct EmbeddedWebNextDetailView: View {
    let redirect: String?
    let onClose: () -> Void

    @StateObject private var model: EmbeddedWebNextModel

    init(
        server: any WebNextServerServiceProtocol,
        redirect: String?,
        onClose: @escaping () -> Void
    ) {
        self.redirect = redirect
        self.onClose = onClose
        _model = StateObject(wrappedValue: EmbeddedWebNextModel(server: server))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: redirect) {
            await model.activate(redirect: redirect)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text("Web Session")
                .font(.headline)
            Spacer(minLength: 0)
            Button("Close", action: onClose)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .connecting:
            EmbeddedWebNextStatusView(state: .connecting)
        case .failed(let reason):
            EmbeddedWebNextStatusView(
                state: .failed(reason),
                onRetry: { Task { await model.activate(redirect: redirect) } }
            )
        case .ready(let signInURL):
            EmbeddedWebNextWebView(signInURL: signInURL)
        }
    }
}

/// The non-webview states of the embedded surface (server starting or failed).
/// Standalone so it renders headless (ImageRenderer) for PR evidence without a
/// running server, and so the detail view stays a thin state switch.
struct EmbeddedWebNextStatusView: View {
    enum State: Equatable {
        case connecting
        case failed(String)
    }

    let state: State
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            switch state {
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                Text("Starting web-next…")
                    .font(.headline)
                Text("Launching the local server and signing you in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn't start web-next")
                    .font(.headline)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Retry") { onRetry?() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// WKWebView bound to the loopback web-next origin. The navigation policy allows
/// only `127.0.0.1` / `localhost` (port is not part of host matching); anything
/// else is treated as an external link and opened in the default browser.
private struct EmbeddedWebNextWebView: NSViewRepresentable {
    let signInURL: URL

    func makeCoordinator() -> WebNavigationPolicy {
        WebNavigationPolicy(
            allowedHost: "127.0.0.1",
            additionalAllowedDomains: ["localhost"],
            allowsSubdomains: false
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: signInURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
