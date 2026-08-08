import Foundation

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
