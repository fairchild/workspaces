import Foundation

struct AppBuildIdentity: Equatable, Sendable {
    enum Channel: String, Equatable, Sendable {
        case development
        case installed
    }

    let channel: Channel
    let displayPath: String?
    let fullPath: String
    let launchPath: String
    let hueDegrees: Double

    var isDevelopment: Bool {
        channel == .development
    }

    static var current: Self {
        resolve(
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL,
            isDebugConfiguration: defaultIsDebugConfiguration
        )
    }

    static func resolve(
        bundleURL: URL,
        executableURL: URL?,
        isDebugConfiguration: Bool
    ) -> Self {
        let resolvedBundleURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedExecutableURL = (executableURL ?? bundleURL).standardizedFileURL.resolvingSymlinksInPath()
        let sourceRootURL = inferredSourceRoot(from: resolvedExecutableURL)
        let isDevelopment = isDebugConfiguration || sourceRootURL != nil
        let displayURL =
            sourceRootURL
            ?? fallbackDisplayURL(
                bundleURL: resolvedBundleURL,
                executableURL: resolvedExecutableURL
            )
        let launchURL = resolvedBundleURL.pathExtension == "app" ? resolvedBundleURL : resolvedExecutableURL
        let fullPath = displayURL.path

        return Self(
            channel: isDevelopment ? .development : .installed,
            displayPath: isDevelopment ? compactDisplayPath(for: displayURL) : nil,
            fullPath: fullPath,
            launchPath: launchURL.path,
            hueDegrees: Double(stableHash(fullPath) % 360)
        )
    }

    static func inferredSourceRoot(from executableURL: URL) -> URL? {
        var currentURL = executableURL.deletingLastPathComponent()

        while currentURL.path != "/" {
            if currentURL.lastPathComponent == ".build" {
                let sourceRootURL = currentURL.deletingLastPathComponent()
                return sourceRootURL.path == "/" ? nil : sourceRootURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return nil
    }

    static func compactDisplayPath(for url: URL) -> String {
        let pathComponents = url.standardizedFileURL.pathComponents.filter { $0 != "/" }

        guard !pathComponents.isEmpty else {
            return url.path
        }

        if let worktreeIndex = pathComponents.firstIndex(of: "worktrees") {
            return pathComponents[worktreeIndex...].joined(separator: "/")
        }

        return pathComponents.suffix(3).joined(separator: "/")
    }

    private static func fallbackDisplayURL(bundleURL: URL, executableURL: URL) -> URL {
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }

        return executableURL.deletingLastPathComponent()
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { partialResult, byte in
            (partialResult ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static var defaultIsDebugConfiguration: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}
