import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WebSourceCreationSupport")
struct WebSourceCreationSupportTests {
    @Test("Duplicate URLs are rejected within the same scope")
    func duplicateURLsRejectedWithinSameScope() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let existing = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            sourceRepo: repo
        )

        let duplicate = WebSourceCreationSupport.duplicateExists(
            normalizedURL: "https://docs.example.com/",
            target: .repo(repo),
            among: [existing]
        )

        #expect(duplicate)
    }

    @Test("Duplicate URLs are allowed across scopes")
    func duplicateURLsAllowedAcrossScopes() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        let existing = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            sourceRepo: repo
        )

        let allowedForWorkspace = WebSourceCreationSupport.duplicateExists(
            normalizedURL: "https://docs.example.com/",
            target: .workspace(workspace),
            among: [existing]
        )
        let allowedForGlobal = WebSourceCreationSupport.duplicateExists(
            normalizedURL: "https://docs.example.com/",
            target: .global,
            among: [existing]
        )

        #expect(!allowedForWorkspace)
        #expect(!allowedForGlobal)
    }
}
