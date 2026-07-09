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
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("EmbeddedWebNext")
struct EmbeddedWebNextTests {
    /// Mirrors the policy the embedded surface installs: loopback-only, exact host.
    private func loopbackPolicy() -> WebNavigationPolicy {
        WebNavigationPolicy(
            allowedHost: "127.0.0.1",
            additionalAllowedDomains: ["localhost"],
            allowsSubdomains: false
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
