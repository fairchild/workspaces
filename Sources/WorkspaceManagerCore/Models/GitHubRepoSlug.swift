//
//  GitHubRepoSlug.swift
//  WorkspaceManagerCore
//
//  Parses `owner/name` out of a git remote URL and builds the embedded
//  web-next create-session deep link (`/new?repo=<owner>/<name>`) from it. Kept
//  provider-agnostic and pure so the sidebar can decide whether a "New Web
//  Session" entry is reachable, and so URL construction is unit-testable without
//  a running server.
//

import Foundation

/// A GitHub repository identity in `owner/name` form, parsed from a git remote.
public struct GitHubRepoSlug: Equatable, Sendable {
    public let owner: String
    public let name: String

    /// `owner/name`, the value the deep-link `repo=` parameter expects.
    public var path: String { "\(owner)/\(name)" }

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parse a slug from a git remote URL. Handles the three forms that reach
    /// this app: `https://github.com/owner/name(.git)`,
    /// `git@github.com:owner/name(.git)` (scp-like), and
    /// `ssh://git@github.com/owner/name(.git)`. Returns nil for anything without
    /// a resolvable two-segment path (a repo the deep link cannot bind to).
    public init?(remoteURL: String?) {
        guard var working = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !working.isEmpty
        else { return nil }

        // Drop the scheme (`https://`, `ssh://`) if present.
        if let schemeRange = working.range(of: "://") {
            working = String(working[schemeRange.upperBound...])
        }
        // Drop any `user@` credential prefix.
        if let atIndex = working.firstIndex(of: "@") {
            working = String(working[working.index(after: atIndex)...])
        }

        let pathPortion: String
        if let colonIndex = working.firstIndex(of: ":") {
            // Either `host:port/path` or scp-style `host:owner/name`.
            let rest = String(working[working.index(after: colonIndex)...])
            if let slashIndex = rest.firstIndex(of: "/"),
                !rest[..<slashIndex].isEmpty,
                rest[..<slashIndex].allSatisfy(\.isNumber)
            {
                pathPortion = String(rest[rest.index(after: slashIndex)...])
            } else {
                pathPortion = rest
            }
        } else if let slashIndex = working.firstIndex(of: "/") {
            pathPortion = String(working[working.index(after: slashIndex)...])
        } else {
            return nil
        }

        var trimmed = pathPortion.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }

        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return nil }

        let owner = String(segments[segments.count - 2])
        let name = String(segments[segments.count - 1])
        guard !owner.isEmpty, !name.isEmpty,
            !owner.contains(where: \.isWhitespace),
            !name.contains(where: \.isWhitespace)
        else { return nil }

        self.owner = owner
        self.name = name
    }
}

/// Relative deep-link paths for the embedded web-next surface, per
/// `web-next/docs/decisions/embedded-native-contract.md` § 3. These become the
/// `redirect` value handed to `WebNextServerServiceProtocol.signInURL(redirect:)`,
/// which the sign-in middleware validates as a relative path and 302s to.
public enum EmbeddedWebNextDeepLink {
    /// Create-session redirect binding the new session to `slug`.
    public static func newSessionRedirect(repo slug: GitHubRepoSlug) -> String {
        "/new?repo=\(slug.path)"
    }
}
