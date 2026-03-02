//
//  ModelsTests.swift
//  WorkspaceManagerTests
//
//  Tests for model behavior: identity, equality, serialization contracts
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Models")
struct ModelsTests {

    // MARK: - FileChange Tests

    @Suite("FileChange")
    struct FileChangeTests {
        @Test("Same path produces same identity regardless of status")
        func identityBasedOnPath() {
            let modified = FileChange(path: "src/main.swift", status: .modified)
            let added = FileChange(path: "src/main.swift", status: .added)

            #expect(modified.id == added.id)
        }

        @Test("Deduplicates by path in a Set")
        func deduplicatesByPath() {
            let a = FileChange(path: "file.txt", status: .modified)
            let b = FileChange(path: "file.txt", status: .modified)
            let c = FileChange(path: "other.txt", status: .modified)

            let set = Set([a, b, c])
            #expect(set.count == 2)
        }

        @Test("Different statuses for same path are not equal")
        func statusAffectsEquality() {
            let modified = FileChange(path: "file.txt", status: .modified)
            let added = FileChange(path: "file.txt", status: .added)

            #expect(modified != added)
        }
    }

    // MARK: - GitStatus Tests

    @Suite("GitStatus")
    struct GitStatusTests {
        @Test("Raw values match git porcelain format")
        func rawValuesMatchGitPorcelain() {
            #expect(GitStatus.modified.rawValue == "M")
            #expect(GitStatus.added.rawValue == "A")
            #expect(GitStatus.deleted.rawValue == "D")
            #expect(GitStatus.untracked.rawValue == "?")
            #expect(GitStatus.renamed.rawValue == "R")
        }
    }

    // MARK: - WorkspaceStatus Tests

    @Suite("WorkspaceStatus")
    struct WorkspaceStatusTests {
        @Test("Survives Codable roundtrip")
        func codableRoundtrip() throws {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()

            for status in WorkspaceStatus.allCases {
                let data = try encoder.encode(status)
                let decoded = try decoder.decode(WorkspaceStatus.self, from: data)
                #expect(decoded == status)
            }
        }
    }

    // MARK: - FileNode Tests

    @Suite("FileNode")
    struct FileNodeTests {
        @Test("Equality based on path")
        func equalityBasedOnPath() {
            let a = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)
            let b = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)
            let c = FileNode(name: "file.txt", path: "other/file.txt", isDirectory: false, children: nil)

            #expect(a == b)
            #expect(a != c)
        }

        @Test("Deduplicates by path in a Set")
        func deduplicatesByPath() {
            let a = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)
            let b = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)

            let set = Set([a, b])
            #expect(set.count == 1)
        }
    }

    // MARK: - WebSourceValidation Tests

    @Suite("WebSourceValidation")
    struct WebSourceValidationTests {
        @Test("Normalizes bare domain into https root URL")
        func normalizeBareDomain() throws {
            let normalized = try WebSourceValidation.normalizeBaseURL("docs.example.com")
            #expect(normalized.baseURL.absoluteString == "https://docs.example.com/")
            #expect(normalized.allowedHost == "docs.example.com")
        }

        @Test("Drops path and query to enforce domain-root base URL")
        func normalizeDropsPathAndQuery() throws {
            let normalized = try WebSourceValidation.normalizeBaseURL(
                "https://app.example.com/products?id=42"
            )
            #expect(normalized.baseURL.absoluteString == "https://app.example.com/")
            #expect(normalized.allowedHost == "app.example.com")
        }

        @Test("Rejects unsupported URL schemes")
        func rejectsUnsupportedSchemes() {
            #expect(throws: WebSourceValidationError.unsupportedScheme("ftp")) {
                try WebSourceValidation.normalizeBaseURL("ftp://example.com")
            }
        }

        @Test("Falls back to host when explicit display name is empty")
        func displayNameFallbacksToHost() throws {
            let normalized = try WebSourceValidation.normalizeBaseURL("https://docs.swift.org")
            let name = WebSourceValidation.normalizedDisplayName(
                explicitName: "   ",
                baseURL: normalized.baseURL
            )
            #expect(name == "docs.swift.org")
        }

        @Test("Builds favicon URL from https host")
        func faviconURLForHTTPSHost() throws {
            let normalized = try WebSourceValidation.normalizeBaseURL("https://docs.example.com")
            let faviconURL = WebSourceValidation.faviconURL(baseURL: normalized.baseURL)
            #expect(faviconURL?.absoluteString == "https://docs.example.com/favicon.ico")
        }

        @Test("Builds favicon URL from http host with port")
        func faviconURLForHTTPHostWithPort() throws {
            let normalized = try WebSourceValidation.normalizeBaseURL("http://localhost:8080")
            let faviconURL = WebSourceValidation.faviconURL(baseURL: normalized.baseURL)
            #expect(faviconURL?.absoluteString == "http://localhost:8080/favicon.ico")
        }

        @Test("Returns nil favicon URL for non-web or hostless URLs")
        func faviconURLRejectsInvalidHostOrScheme() {
            #expect(WebSourceValidation.faviconURL(baseURL: URL(fileURLWithPath: "/tmp/index.html")) == nil)
            #expect(WebSourceValidation.faviconURL(baseURL: URL(string: "/relative/path")!) == nil)
        }

        @Test("Host policy allows exact host and subdomains")
        func hostPolicyAllowsSubdomains() {
            #expect(
                WebSourceValidation.host(
                    "docs.example.com",
                    isAllowedFor: "example.com",
                    allowsSubdomains: true
                )
            )
            #expect(
                WebSourceValidation.host(
                    "example.com",
                    isAllowedFor: "example.com",
                    allowsSubdomains: true
                )
            )
            #expect(
                !WebSourceValidation.host(
                    "example.net",
                    isAllowedFor: "example.com",
                    allowsSubdomains: true
                )
            )
        }

        @Test("Additional allowlist normalization supports wildcard and deduplicates values")
        func normalizeAdditionalAllowlistDomains() throws {
            let domains = try WebSourceValidation.normalizeAdditionalAllowedDomains(
                " api.example.com, *.example.org\nAPI.example.com \n"
            )
            #expect(domains == ["api.example.com", "*.example.org"])
        }

        @Test("Additional allowlist normalization rejects invalid domains")
        func rejectInvalidAdditionalAllowlistDomain() {
            #expect(throws: WebSourceValidationError.invalidAllowlistedDomain("https://example.com")) {
                try WebSourceValidation.normalizeAdditionalAllowedDomains("https://example.com")
            }
            #expect(throws: WebSourceValidationError.invalidAllowlistedDomain("*.bad/domain")) {
                try WebSourceValidation.normalizeAdditionalAllowedDomains("*.bad/domain")
            }
        }

        @Test("Allowlist host matching supports wildcard entries")
        func allowlistHostMatchingSupportsWildcard() {
            #expect(WebSourceValidation.host("example.com", matchesAllowlistDomain: "*.example.com"))
            #expect(WebSourceValidation.host("docs.example.com", matchesAllowlistDomain: "*.example.com"))
            #expect(!WebSourceValidation.host("example.net", matchesAllowlistDomain: "*.example.com"))
            #expect(WebSourceValidation.host("api.example.com", matchesAllowlistDomain: "api.example.com"))
            #expect(!WebSourceValidation.host("www.api.example.com", matchesAllowlistDomain: "api.example.com"))
        }
    }
}
