import Foundation
import SwiftUI
import WorkspaceManagerCore

/// Memoizes ``MainWindowPathResolution/normalize(_:)`` — each normalization is
/// tilde expansion plus symlink resolution (`lstat` per path component), which
/// must not run per repo per render (#1347 B1). Held in a view's `@State` so
/// the instance survives body evaluations without registering observation.
///
/// Staleness contract: a cached resolution goes stale only if the filesystem
/// changes under an already-seen raw path (a directory re-symlinked mid-run).
/// New paths always miss into a fresh resolution.
@MainActor
final class PathNormalizationCache {
    private struct RepoIndexFingerprint: Equatable {
        let paths: [String]
        /// Object identity, not just stored paths: SwiftData can replace a
        /// repo instance at the same path, and duplicate-path repos can swap
        /// order — both must rebuild the first-wins index.
        let identities: [ObjectIdentifier]
    }

    private var normalizedByRawPath: [String: String] = [:]
    private var repoIndexFingerprint: RepoIndexFingerprint?
    private var repoIndexCache: [String: Repo] = [:]

    /// Entry bound before the whole cache resets; render paths touch a handful
    /// of stable paths, so hitting this means something is generating paths.
    private let capacity = 4096

    func normalize(_ rawPath: String) -> String {
        if let cached = normalizedByRawPath[rawPath] { return cached }
        let normalized = MainWindowPathResolution.normalize(rawPath)
        if normalizedByRawPath.count >= capacity {
            normalizedByRawPath.removeAll(keepingCapacity: true)
        }
        normalizedByRawPath[rawPath] = normalized
        return normalized
    }

    /// Normalized-path → repo index, rebuilt only when the repo set (by stored
    /// path) changes. First repo wins on a normalized-path collision, matching
    /// the uncached index this replaces.
    func repoIndex(repos: [Repo]) -> [String: Repo] {
        let fingerprint = RepoIndexFingerprint(
            paths: repos.map(\.localPath),
            identities: repos.map(ObjectIdentifier.init)
        )
        if fingerprint == repoIndexFingerprint { return repoIndexCache }

        var index: [String: Repo] = [:]
        index.reserveCapacity(repos.count)
        for repo in repos {
            let normalizedPath = normalize(repo.localPath)
            if index[normalizedPath] == nil {
                index[normalizedPath] = repo
            }
        }
        repoIndexFingerprint = fingerprint
        repoIndexCache = index
        return index
    }
}

/// Path arithmetic the main window's selection wiring and its view share: canonical
/// normalization, containment, and the directory a terminal session should actually
/// launch in. Pure statics so a controller can reach them without carrying a collaborator.
enum MainWindowPathResolution {
    /// Canonical form for comparing two filesystem paths: tilde expanded, standardized,
    /// symlinks resolved. Shares one implementation with the restore lane so a path
    /// compared here and a path compared there agree.
    static func normalize(_ rawPath: String) -> String {
        RestorePathNormalization.normalize(rawPath)
    }

    /// `true` when `path` is `root` or lives beneath it. Compares canonical strings, so
    /// callers normalize inputs that may carry `~` or symlinks first.
    static func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }

    /// The directory a session opens in: `preferredDirectory` when it is an existing
    /// directory inside `root`, `root` otherwise. Restored launch directories and deep-link
    /// cwds both arrive unvalidated, so a stale or escaped path lands on the root rather
    /// than somewhere the user did not select.
    static func preferredSessionDirectory(_ preferredDirectory: URL?, inside root: URL) -> URL {
        guard let preferredDirectory else { return root }

        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedPreferred = preferredDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard path(normalizedPreferred.path, isInside: normalizedRoot.path) else {
            return normalizedRoot
        }

        var isDirectory = ObjCBool(false)
        guard
            FileManager.default.fileExists(atPath: normalizedPreferred.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return normalizedRoot
        }

        return normalizedPreferred
    }
}
