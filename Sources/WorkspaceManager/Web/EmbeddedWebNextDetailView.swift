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
        // `start()` returns immediately when a launch is already in flight
        // (state `.starting`), so a second activation racing the first must not
        // sample state once and conclude failure — wait for the launch to reach
        // a terminal `.ready`/`.failed` transition.
        await server.start()

        switch await awaitTerminalState() {
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

    /// Poll until the server leaves `.starting`, so an activation that raced an
    /// in-flight launch resolves on the real outcome. This is only a backstop
    /// against a wedged launch that never transitions; it must stay comfortably
    /// past the service's own `readinessTimeout` (currently 180s, sized for a
    /// cold first-run build) so the UI never gives up on a launch the service
    /// still considers healthy-in-progress.
    private func awaitTerminalState() async -> WebNextServerState {
        var state = await server.state
        var elapsed: TimeInterval = 0
        let pollInterval: TimeInterval = 0.15
        let maxWait: TimeInterval = 210
        while case .starting = state, elapsed < maxWait, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            elapsed += pollInterval
            state = await server.state
        }
        return state
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
                Text(
                    "Launching the local server and signing you in. The first run builds web-next and can take a minute."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
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

/// WKWebView bound to the loopback web-next origin, pinned to both host
/// (`127.0.0.1` / `localhost`) AND the server port so the token-bearing session
/// cookie can't leak to another local service; anything else is treated as an
/// external link and opened in the default browser. The webview uses a
/// non-persistent data store so the session cookie dies with the pane rather
/// than surviving across app runs on disk.
struct EmbeddedWebNextWebView: NSViewRepresentable {
    let signInURL: URL

    func makeCoordinator() -> WebNavigationPolicy {
        WebNavigationPolicy(
            allowedHost: "127.0.0.1",
            additionalAllowedDomains: ["localhost"],
            allowsSubdomains: false,
            allowedPort: signInURL.port
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: signInURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    /// Ephemeral, in-memory configuration: the bearer session cookie must not
    /// persist to disk across runs.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}
