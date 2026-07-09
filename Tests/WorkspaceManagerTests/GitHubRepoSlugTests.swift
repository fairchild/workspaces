//
//  GitHubRepoSlugTests.swift
//  WorkspaceManagerTests
//
//  Parsing of `owner/name` from the git remote forms this app sees, and the
//  create-session deep-link path built from a slug.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("GitHubRepoSlug")
struct GitHubRepoSlugTests {
    @Test("Parses HTTPS remotes with and without the .git suffix")
    func parsesHTTPS() {
        #expect(
            GitHubRepoSlug(remoteURL: "https://github.com/fairchild/workspaces.git")
                == GitHubRepoSlug(owner: "fairchild", name: "workspaces"))
        #expect(
            GitHubRepoSlug(remoteURL: "https://github.com/fairchild/workspaces")
                == GitHubRepoSlug(owner: "fairchild", name: "workspaces"))
        #expect(
            GitHubRepoSlug(remoteURL: "https://github.com/fairchild/workspaces/")
                == GitHubRepoSlug(owner: "fairchild", name: "workspaces"))
    }

    @Test("Parses scp-style and ssh remotes")
    func parsesSSH() {
        #expect(
            GitHubRepoSlug(remoteURL: "git@github.com:fairchild/workspaces.git")
                == GitHubRepoSlug(owner: "fairchild", name: "workspaces"))
        #expect(
            GitHubRepoSlug(remoteURL: "ssh://git@github.com/fairchild/workspaces.git")
                == GitHubRepoSlug(owner: "fairchild", name: "workspaces"))
    }

    @Test("Preserves dotted repo names")
    func preservesDottedName() {
        #expect(
            GitHubRepoSlug(remoteURL: "https://github.com/acme/my.tool.git")
                == GitHubRepoSlug(owner: "acme", name: "my.tool"))
    }

    @Test("Returns nil for unresolvable remotes")
    func returnsNilForUnresolvable() {
        #expect(GitHubRepoSlug(remoteURL: nil) == nil)
        #expect(GitHubRepoSlug(remoteURL: "") == nil)
        #expect(GitHubRepoSlug(remoteURL: "   ") == nil)
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/owneronly") == nil)
        #expect(GitHubRepoSlug(remoteURL: "not-a-url") == nil)
    }

    @Test("Builds the create-session redirect path")
    func buildsRedirect() {
        let slug = GitHubRepoSlug(owner: "fairchild", name: "workspaces")
        #expect(EmbeddedWebNextDeepLink.newSessionRedirect(repo: slug) == "/new?repo=fairchild/workspaces")
    }
}
