//
//  ModelsTests.swift
//  WorkspaceManagerTests
//
//  Tests for model behavior: identity, equality, serialization contracts
//

import Foundation
import SwiftData
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

    @Suite("RemoteWorkspaceMetadata")
    struct RemoteWorkspaceMetadataTests {
        @Test("SSH metadata survives Codable roundtrip")
        func sshMetadataRoundtrip() throws {
            let metadata = SSHWorkspaceMetadata(
                host: "ssh.example.com",
                user: "alice",
                authMode: "key",
                workingDir: "/workspace"
            )

            let data = try JSONEncoder().encode(metadata)
            let decoded = try JSONDecoder().decode(SSHWorkspaceMetadata.self, from: data)

            #expect(decoded == metadata)
            #expect(decoded.port == 22)
        }

        @Test("Kubernetes metadata survives Codable roundtrip")
        func kubernetesMetadataRoundtrip() throws {
            let metadata = KubernetesWorkspaceMetadata(
                context: "prod-cluster",
                namespace: "payments",
                deployment: "api",
                container: "web"
            )

            let data = try JSONEncoder().encode(metadata)
            let decoded = try JSONDecoder().decode(KubernetesWorkspaceMetadata.self, from: data)

            #expect(decoded == metadata)
        }

        @Test("Compose metadata survives Codable roundtrip")
        func composeMetadataRoundtrip() throws {
            let metadata = ComposeWorkspaceMetadata(
                projectName: "acme",
                composeFiles: ["compose.yml", "compose.dev.yml"],
                service: "web",
                workdir: "/app"
            )

            let data = try JSONEncoder().encode(metadata)
            let decoded = try JSONDecoder().decode(ComposeWorkspaceMetadata.self, from: data)

            #expect(decoded == metadata)
        }

        @Test("SSH and Compose metadata coexist in additive payload")
        func sshAndComposeMetadataCoexist() {
            let workspace = makeWorkspace()
            let ssh = SSHWorkspaceMetadata(
                host: "ssh.example.com",
                user: "alice",
                authMode: "key",
                workingDir: "/workspace"
            )
            let compose = ComposeWorkspaceMetadata(
                projectName: "acme",
                composeFiles: ["compose.yml"],
                service: "web"
            )

            workspace.sshMetadata = ssh
            workspace.composeMetadata = compose

            #expect(workspace.sshMetadata == ssh)
            #expect(workspace.composeMetadata == compose)
            #expect(workspace.remoteMetadataJSON.contains(#""ssh""#))
            #expect(workspace.remoteMetadataJSON.contains(#""compose""#))
            #expect(!workspace.remoteMetadataJSON.contains(#""kind""#))
        }

        @Test("Legacy kind payloads decode into additive payload")
        func legacyKindPayloadsDecodeIntoAdditivePayload() {
            let workspace = makeWorkspace()

            workspace.remoteMetadataJSON =
                #"{"kind":"ssh","ssh":{"host":"ssh.example.com","user":"alice","port":22,"authMode":"key","workingDir":"/workspace"}}"#

            #expect(
                workspace.sshMetadata
                    == SSHWorkspaceMetadata(
                        host: "ssh.example.com",
                        user: "alice",
                        authMode: "key",
                        workingDir: "/workspace"
                    )
            )
            #expect(workspace.composeMetadata == nil)
            #expect(workspace.kubernetesMetadata == nil)

            workspace.remoteMetadataJSON =
                #"{"kind":"compose","compose":{"projectName":"acme","composeFiles":["compose.yml"],"service":"web","workdir":"/app"}}"#

            #expect(workspace.sshMetadata == nil)
            #expect(
                workspace.composeMetadata
                    == ComposeWorkspaceMetadata(
                        projectName: "acme",
                        composeFiles: ["compose.yml"],
                        service: "web",
                        workdir: "/app"
                    )
            )
        }

        @Test("Additive payload wins when kind is present alongside new metadata")
        func additivePayloadWinsWhenKindIsPresent() {
            let workspace = makeWorkspace()

            workspace.remoteMetadataJSON =
                #"{"kind":"ssh","ssh":{"host":"ssh.example.com","user":"alice","port":22,"authMode":"key","workingDir":"/workspace"},"compose":{"projectName":"acme","composeFiles":["compose.yml"],"service":"web","workdir":"/app"}}"#

            #expect(
                workspace.sshMetadata
                    == SSHWorkspaceMetadata(
                        host: "ssh.example.com",
                        user: "alice",
                        authMode: "key",
                        workingDir: "/workspace"
                    )
            )
            #expect(
                workspace.composeMetadata
                    == ComposeWorkspaceMetadata(
                        projectName: "acme",
                        composeFiles: ["compose.yml"],
                        service: "web",
                        workdir: "/app"
                    )
            )
        }

        @Test("Clearing Compose metadata preserves SSH metadata")
        func clearingComposePreservesSSHMetadata() {
            let workspace = makeWorkspace()
            let ssh = SSHWorkspaceMetadata(
                host: "ssh.example.com",
                user: "alice",
                authMode: "key",
                workingDir: "/workspace"
            )
            let compose = ComposeWorkspaceMetadata(
                composeFiles: ["compose.yml"],
                service: "web"
            )

            workspace.sshMetadata = ssh
            workspace.composeMetadata = compose
            workspace.composeMetadata = nil

            #expect(workspace.composeMetadata == nil)
            #expect(workspace.sshMetadata == ssh)
            #expect(workspace.remoteMetadataJSON.contains(#""ssh""#))
            #expect(!workspace.remoteMetadataJSON.contains(#""compose""#))
        }

        @Test("Empty, malformed, and unknown metadata payloads decode as nil")
        func invalidOrUnknownMetadataPayloadsDecodeAsNil() {
            let workspace = makeWorkspace()

            #expect(workspace.sshMetadata == nil)
            #expect(workspace.kubernetesMetadata == nil)
            #expect(workspace.composeMetadata == nil)

            workspace.remoteMetadataJSON = "{not-json"
            #expect(workspace.sshMetadata == nil)
            #expect(workspace.kubernetesMetadata == nil)
            #expect(workspace.composeMetadata == nil)

            workspace.remoteMetadataJSON = #"{"kind":"docker","compose":{"service":"web"}}"#
            #expect(workspace.sshMetadata == nil)
            #expect(workspace.kubernetesMetadata == nil)
            #expect(workspace.composeMetadata == nil)
        }

        @Test("Legacy Daytona workspace stays remote without metadata")
        func legacyDaytonaWorkspaceStaysRemoteWithoutMetadata() {
            let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
            let workspace = Workspace(
                name: "cloud-feature",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/cloud-feature"),
                sourceRepo: repo,
                backendIdentifier: "daytona",
                remoteId: "sandbox-123"
            )

            #expect(workspace.isRemote)
            #expect(workspace.remoteId == "sandbox-123")
            #expect(workspace.remoteMetadataJSON.isEmpty)
            #expect(workspace.sshMetadata == nil)
            #expect(workspace.kubernetesMetadata == nil)
            #expect(workspace.composeMetadata == nil)
        }

        @Test("Remote workspaces do not expose a local directory URL")
        func remoteWorkspaceDoesNotExposeLocalDirectoryURL() {
            let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
            let remoteWorkspace = Workspace(
                name: "cloud-feature",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/cloud-feature"),
                sourceRepo: repo,
                backendIdentifier: SSHBackend.identifier,
                remoteId: "remote-123"
            )
            let localWorkspace = Workspace(
                name: "feature-a",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
                sourceRepo: repo
            )

            #expect(remoteWorkspace.localDirectoryURL == nil)
            #expect(localWorkspace.localDirectoryURL == localWorkspace.workspaceURL)
        }

        @Test("Remote session request snapshots repo and metadata state")
        func remoteSessionRequestSnapshotsRepoAndMetadataState() {
            let repo = Repo(
                name: "alpha",
                localPath: URL(fileURLWithPath: "/tmp/alpha"),
                remoteURL: "git@github.com:acme/alpha.git"
            )
            let workspace = Workspace(
                name: "cloud-feature",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/cloud-feature"),
                sourceRepo: repo,
                backendIdentifier: SSHBackend.identifier,
                remoteId: "remote-123"
            )
            let ssh = SSHWorkspaceMetadata(host: "ssh.example.com", user: "alice", port: 2222)
            let compose = ComposeWorkspaceMetadata(composeFiles: ["compose.yml"], service: "web")
            workspace.status = .stopped
            workspace.sshMetadata = ssh
            workspace.composeMetadata = compose

            let request = workspace.remoteSessionRequest

            #expect(request.workspaceID == workspace.id)
            #expect(request.name == "cloud-feature")
            #expect(request.backendIdentifier == SSHBackend.identifier)
            #expect(request.remoteId == "remote-123")
            #expect(request.status == .stopped)
            #expect(request.repoName == "alpha")
            #expect(request.repoRemoteURL == "git@github.com:acme/alpha.git")
            #expect(request.sshMetadata == ssh)
            #expect(request.composeMetadata == compose)
        }

        @Test("Workspace persists empty remote metadata JSON by default")
        @MainActor
        func workspacePersistsEmptyRemoteMetadataJSONByDefault() throws {
            let schema = Schema([Repo.self, Workspace.self, WebSource.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
            let workspace = Workspace(
                name: "cloud-feature",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/cloud-feature"),
                sourceRepo: repo,
                backendIdentifier: "daytona",
                remoteId: "sandbox-123"
            )

            context.insert(repo)
            context.insert(workspace)
            try context.save()

            let fetched = try context.fetch(FetchDescriptor<Workspace>())

            #expect(fetched.count == 1)
            #expect(fetched[0].remoteMetadataJSON.isEmpty)
            #expect(fetched[0].remoteId == "sandbox-123")
            #expect(fetched[0].sshMetadata == nil)
        }

        private func makeWorkspace() -> Workspace {
            let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
            return Workspace(
                name: "feature-a",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
                sourceRepo: repo
            )
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

    @Suite("WebSourceOwnership")
    struct WebSourceOwnershipTests {
        @Test("Global sources report global ownership")
        func globalSourceOwnership() {
            let source = WebSource(
                name: "Docs",
                baseURLString: "https://docs.example.com/",
                allowedHost: "docs.example.com"
            )

            #expect(source.isGlobal)
            #expect(source.ownershipScope == .global)
            #expect(source.ownerRepo == nil)
        }

        @Test("Repo-owned sources derive repo ownership")
        func repoOwnedSourceOwnership() {
            let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
            let source = WebSource(
                name: "Docs",
                baseURLString: "https://docs.example.com/",
                allowedHost: "docs.example.com",
                sourceRepo: repo
            )

            #expect(!source.isGlobal)
            #expect(source.ownershipScope == .repo(repo.id))
            #expect(source.ownerRepo?.id == repo.id)
        }

        @Test("Workspace-owned sources derive workspace scope and repo owner")
        func workspaceOwnedSourceOwnership() {
            let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
            let workspace = Workspace(
                name: "feature-a",
                path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
                sourceRepo: repo
            )
            let source = WebSource(
                name: "Docs",
                baseURLString: "https://docs.example.com/",
                allowedHost: "docs.example.com",
                sourceWorkspace: workspace
            )

            #expect(source.ownershipScope == .workspace(workspace.id))
            #expect(source.ownerRepo?.id == repo.id)
        }
    }
}
