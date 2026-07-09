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

    @Test("Rejects segments outside GitHub's charset (query/fragment injection)")
    func rejectsInjectionChars() {
        // A crafted remote whose name would inject a second query param once the
        // deep link is decoded, or carries URL-significant characters.
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/acme/repo&title=pwn.git") == nil)
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/acme/a?b.git") == nil)
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/acme/a#b.git") == nil)
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/acme/a b.git") == nil)
    }

    @Test("Rejects dot-only path-traversal segments")
    func rejectsTraversal() {
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/acme/...git") == nil)  // name ".."
        #expect(GitHubRepoSlug(remoteURL: "git@github.com:../workspaces.git") == nil)  // owner ".."
        #expect(GitHubRepoSlug(remoteURL: "https://github.com/./workspaces") == nil)  // owner "."
        // A legitimate dotted repo name must still resolve.
        #expect(
            GitHubRepoSlug(remoteURL: "https://github.com/acme/my.tool.git")
                == GitHubRepoSlug(owner: "acme", name: "my.tool"))
    }

    @Test("Builds the create-session redirect path")
    func buildsRedirect() {
        let slug = GitHubRepoSlug(owner: "fairchild", name: "workspaces")
        #expect(EmbeddedWebNextDeepLink.newSessionRedirect(repo: slug) == "/new?repo=fairchild/workspaces")
    }
}
