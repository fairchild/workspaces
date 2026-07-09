//
//  EmbeddedWebNextTests.swift
//  WorkspaceManagerAppTests
//
//  Behavior for the embedded web-next surface: the loopback navigation
//  allowlist and the repo-bound New Web Session deep link resolved from a
//  workspace's owning repo.
//

import Foundation
import Testing
import WebKit
import WorkspaceManagerCore

@testable import WorkspaceManager

/// Controllable stub so the model's startup-race handling can be tested without
/// a real server: `start()` is a no-op (the test drives `state` directly),
/// mirroring the real actor returning immediately while already `.starting`.
private actor StubWebNextServer: WebNextServerServiceProtocol {
    private var currentState: WebNextServerState

    init(state: WebNextServerState) { currentState = state }

    var state: WebNextServerState { currentState }
    func transition(to next: WebNextServerState) { currentState = next }

    func start() async {}
    func stop() async { currentState = .idle }
    func stopForTermination() async { currentState = .idle }
    func signInURL(redirect: String?) async -> URL? {
        URL(string: "http://127.0.0.1:3140/sign-in?token=stub")
    }
}

@MainActor
@Suite("EmbeddedWebNext")
struct EmbeddedWebNextTests {
    /// Mirrors the policy the embedded surface installs: loopback host pinned to
    /// the server port.
    private func loopbackPolicy() -> WebNavigationPolicy {
        WebNavigationPolicy(
            allowedHost: "127.0.0.1",
            additionalAllowedDomains: ["localhost"],
            allowsSubdomains: false,
            allowedPort: 3140
        )
    }

    @Test("Loopback policy allows 127.0.0.1 and localhost on the server port")
    func loopbackAllowed() {
        let policy = loopbackPolicy()
        #expect(policy.shouldAllow(url: URL(string: "http://127.0.0.1:3140/sign-in?token=abc")!))
        #expect(policy.shouldAllow(url: URL(string: "http://localhost:3140/sessions/1")!))
        #expect(policy.shouldAllow(url: URL(string: "http://127.0.0.1:3140/new?repo=a/b")!))
    }

    @Test("Loopback policy rejects non-loopback hosts")
    func nonLoopbackRejected() {
        let policy = loopbackPolicy()
        #expect(!policy.shouldAllow(url: URL(string: "https://github.com/login")!))
        #expect(!policy.shouldAllow(url: URL(string: "http://127.0.0.1.evil.com/")!))
        #expect(!policy.shouldAllow(url: URL(string: "http://example.com:3140/")!))
        #expect(!policy.shouldAllow(url: URL(string: "file:///etc/passwd")!))
    }

    @Test("Loopback policy rejects other ports on the same host (cookie scoping)")
    func crossPortRejected() {
        let policy = loopbackPolicy()
        #expect(!policy.shouldAllow(url: URL(string: "http://127.0.0.1:3141/sessions/1")!))
        #expect(!policy.shouldAllow(url: URL(string: "http://127.0.0.1:9999/")!))
        #expect(!policy.shouldAllow(url: URL(string: "http://localhost:3141/")!))
        // The configured port on either loopback host still passes.
        #expect(policy.shouldAllow(url: URL(string: "http://127.0.0.1:3140/")!))
        #expect(policy.shouldAllow(url: URL(string: "http://localhost:3140/")!))
    }

    @Test("Embedded webview configuration is non-persistent (ephemeral cookie)")
    func webviewNonPersistent() {
        let configuration = EmbeddedWebNextWebView.makeConfiguration()
        #expect(configuration.websiteDataStore.isPersistent == false)
    }

    @Test("New Web Session forces a fresh activation even for the same repo")
    func forceFreshActivation() throws {
        let redirect = "/new?repo=fairchild/workspaces"
        let first = try #require(
            EmbeddedWebNextActivation.next(current: nil, redirect: redirect, forceFresh: true))
        let second = try #require(
            EmbeddedWebNextActivation.next(current: first, redirect: redirect, forceFresh: true))
        #expect(first.id != second.id, "each New Web Session must be a distinct activation")

        // The plain shortcut re-opening the same surface is a no-op.
        #expect(
            EmbeddedWebNextActivation.next(current: first, redirect: redirect, forceFresh: false) == nil)
        // A different redirect always opens.
        #expect(
            EmbeddedWebNextActivation.next(current: first, redirect: "/", forceFresh: false) != nil)
    }

    @Test("Activation racing an in-flight launch resolves on ready, not a spurious failure")
    func activationAwaitsReady() async {
        let base = URL(string: "http://127.0.0.1:3140")!
        let stub = StubWebNextServer(state: .starting)
        let model = EmbeddedWebNextModel(server: stub)

        async let activation: Void = model.activate(redirect: "/new?repo=a/b")
        // The in-flight launch reaches ready shortly after the second activation.
        try? await Task.sleep(nanoseconds: 250_000_000)
        await stub.transition(to: .ready(signInBaseURL: base))
        await activation

        #expect(
            model.phase == .ready(URL(string: "http://127.0.0.1:3140/sign-in?token=stub")!),
            "must await the real .ready, not sample .starting once and fail")
    }

    @Test("New Web Session deep link resolves from a workspace's owning repo")
    func deepLinkFromWorkspace() {
        let repo = Repo(
            name: "workspaces",
            localPath: URL(fileURLWithPath: "/tmp/workspaces"),
            remoteURL: "git@github.com:fairchild/workspaces.git"
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/workspaces/wt/feature-a"),
            sourceRepo: repo
        )

        let slug = GitHubRepoSlug(remoteURL: workspace.sourceRepo?.remoteURL)
        #expect(slug == GitHubRepoSlug(owner: "fairchild", name: "workspaces"))
        #expect(
            EmbeddedWebNextDeepLink.newSessionRedirect(repo: slug!)
                == "/new?repo=fairchild/workspaces"
        )
    }

    @Test("New Web Session is unavailable when the repo has no resolvable remote")
    func deepLinkUnavailableWithoutRemote() {
        let repo = Repo(
            name: "local-only",
            localPath: URL(fileURLWithPath: "/tmp/local-only"),
            remoteURL: nil
        )
        #expect(GitHubRepoSlug(remoteURL: repo.remoteURL) == nil)
    }
}
