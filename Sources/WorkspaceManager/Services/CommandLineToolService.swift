import Darwin
import Foundation

enum CommandLineToolAvailability: Equatable {
    case installed
    case notInstalled
    case unavailable
}

enum CommandLineToolPrimaryAction: Equatable {
    case install
    case repair

    var title: String {
        switch self {
        case .install:
            return "Install"
        case .repair:
            return "Repair"
        }
    }
}

enum CommandLineToolStatusReason: Equatable {
    case active
    case missing
    case missingFromPath
    case brokenSymlink
    case differentTarget(existingTargetPath: String?)
    case conflictingFile
    case shadowedByOtherCommand(path: String)
    case missingBundledCommand
    case noWritableInstallLocation
}

struct CommandLineToolStatus: Equatable {
    let availability: CommandLineToolAvailability
    let reason: CommandLineToolStatusReason
    let commandPath: String?
    let sourcePath: String?
    let setupCommand: String?
    let primaryAction: CommandLineToolPrimaryAction?
}

enum CommandLineToolInstallError: LocalizedError, Equatable {
    case missingBundledCommand
    case noWritableInstallLocation
    case conflictingFile(path: String)
    case installFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingBundledCommand:
            return "This build does not include the bundled workspaces launcher."
        case .noWritableInstallLocation:
            return "No writable install location was found for the workspaces command."
        case .conflictingFile(let path):
            return "A different file already exists at \(path). Move or rename it before installing."
        case .installFailed(let reason):
            return "Failed to install the workspaces command: \(reason)"
        }
    }
}

struct CommandLineToolService {
    private static let commandName = "workspaces"

    private let fileManager: FileManager
    private let environment: [String: String]
    private let sourceCommandURL: URL?
    private let preferredInstallDirectories: [URL]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceCommandURL: URL? = nil,
        preferredInstallDirectories: [URL]? = nil,
        homeDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        let resolvedSourceCommandURL =
            sourceCommandURL
            ?? CommandLineToolService.defaultSourceCommandURL(fileManager: fileManager)
        self.sourceCommandURL = resolvedSourceCommandURL?.standardizedFileURL.resolvingSymlinksInPath()

        let resolvedHomeDirectory =
            homeDirectoryURL?.standardizedFileURL
            ?? fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        self.preferredInstallDirectories =
            preferredInstallDirectories?.map { $0.standardizedFileURL }
            ?? Self.defaultPreferredInstallDirectories(homeDirectoryURL: resolvedHomeDirectory)
    }

    func status() -> CommandLineToolStatus {
        guard let sourceCommandURL, fileManager.isExecutableFile(atPath: sourceCommandURL.path) else {
            return CommandLineToolStatus(
                availability: .unavailable,
                reason: .missingBundledCommand,
                commandPath: nil,
                sourcePath: sourceCommandURL?.path,
                setupCommand: nil,
                primaryAction: nil
            )
        }

        let sourcePath = normalizePath(sourceCommandURL)
        let pathDirectories = resolvedPathDirectories()

        if let activeCommandPath = activeCommandPath(
            pathDirectories: pathDirectories,
            sourcePath: sourcePath
        ) {
            return CommandLineToolStatus(
                availability: .installed,
                reason: .active,
                commandPath: activeCommandPath,
                sourcePath: sourceCommandURL.path,
                setupCommand: nil,
                primaryAction: nil
            )
        }

        let candidateDirectories = candidateDirectories(pathDirectories: pathDirectories)
        let preferredCommandURL =
            managedCommandURL(
                sourcePath: sourcePath,
                candidateDirectories: candidateDirectories
            )
            ?? resolvedInstallCommandURL(pathDirectories: pathDirectories)

        guard let preferredCommandURL else {
            return CommandLineToolStatus(
                availability: .unavailable,
                reason: .noWritableInstallLocation,
                commandPath: nil,
                sourcePath: sourceCommandURL.path,
                setupCommand: nil,
                primaryAction: nil
            )
        }

        let shadowingCommandPath = shadowingCommandPath(
            pathDirectories: pathDirectories,
            sourcePath: sourcePath
        )
        let commandPath = preferredCommandURL.path
        let directoryOnPath = pathDirectories.contains {
            sameDirectory($0, preferredCommandURL.deletingLastPathComponent())
        }
        let shouldPrependPath = shadowingCommandPath != nil || !directoryOnPath
        let setupCommand = makeSetupCommand(
            sourceCommandURL: sourceCommandURL,
            installCommandURL: preferredCommandURL,
            prependToPath: shouldPrependPath
        )

        let preferredEntry = pathEntry(at: preferredCommandURL)

        if let shadowingCommandPath {
            if shadowingCommandPath == commandPath {
                switch preferredEntry {
                case .otherSymlink(let existingTargetPath):
                    return CommandLineToolStatus(
                        availability: .notInstalled,
                        reason: .differentTarget(existingTargetPath: existingTargetPath),
                        commandPath: commandPath,
                        sourcePath: sourceCommandURL.path,
                        setupCommand: setupCommand,
                        primaryAction: .repair
                    )
                case .brokenSymlink:
                    return CommandLineToolStatus(
                        availability: .notInstalled,
                        reason: .brokenSymlink,
                        commandPath: commandPath,
                        sourcePath: sourceCommandURL.path,
                        setupCommand: setupCommand,
                        primaryAction: .repair
                    )
                case .file:
                    return CommandLineToolStatus(
                        availability: .notInstalled,
                        reason: .conflictingFile,
                        commandPath: commandPath,
                        sourcePath: sourceCommandURL.path,
                        setupCommand: setupCommand,
                        primaryAction: nil
                    )
                case .missing:
                    break
                }
            }

            let existingManagedCommand = preferredEntry.resolvesTo(path: sourcePath)
            return CommandLineToolStatus(
                availability: .notInstalled,
                reason: .shadowedByOtherCommand(path: shadowingCommandPath),
                commandPath: commandPath,
                sourcePath: sourceCommandURL.path,
                setupCommand: setupCommand,
                primaryAction: existingManagedCommand ? nil : .install
            )
        }

        switch preferredEntry {
        case .missing:
            return CommandLineToolStatus(
                availability: .notInstalled,
                reason: .missing,
                commandPath: commandPath,
                sourcePath: sourceCommandURL.path,
                setupCommand: setupCommand,
                primaryAction: .install
            )
        case .otherSymlink(let existingTargetPath):
            if existingTargetPath == sourcePath {
                return CommandLineToolStatus(
                    availability: .notInstalled,
                    reason: .missingFromPath,
                    commandPath: commandPath,
                    sourcePath: sourceCommandURL.path,
                    setupCommand: setupCommand,
                    primaryAction: nil
                )
            }
            return CommandLineToolStatus(
                availability: .notInstalled,
                reason: .differentTarget(existingTargetPath: existingTargetPath),
                commandPath: commandPath,
                sourcePath: sourceCommandURL.path,
                setupCommand: setupCommand,
                primaryAction: .repair
            )
        case .brokenSymlink:
            return CommandLineToolStatus(
                availability: .notInstalled,
                reason: .brokenSymlink,
                commandPath: commandPath,
                sourcePath: sourceCommandURL.path,
                setupCommand: setupCommand,
                primaryAction: .repair
            )
        case .file:
            return CommandLineToolStatus(
                availability: .notInstalled,
                reason: .conflictingFile,
                commandPath: commandPath,
                sourcePath: sourceCommandURL.path,
                setupCommand: setupCommand,
                primaryAction: nil
            )
        }
    }

    func installOrRepair() throws -> CommandLineToolStatus {
        let currentStatus = status()

        guard let sourcePath = currentStatus.sourcePath,
            let commandPath = currentStatus.commandPath
        else {
            switch currentStatus.reason {
            case .missingBundledCommand:
                throw CommandLineToolInstallError.missingBundledCommand
            case .noWritableInstallLocation:
                throw CommandLineToolInstallError.noWritableInstallLocation
            default:
                throw CommandLineToolInstallError.installFailed(reason: "Missing install metadata.")
            }
        }

        let sourceCommandURL = URL(fileURLWithPath: sourcePath)
        let installCommandURL = URL(fileURLWithPath: commandPath)

        if !fileManager.isExecutableFile(atPath: sourceCommandURL.path) {
            throw CommandLineToolInstallError.missingBundledCommand
        }

        try fileManager.createDirectory(
            at: installCommandURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch pathEntry(at: installCommandURL) {
        case .file:
            throw CommandLineToolInstallError.conflictingFile(path: installCommandURL.path)
        case .otherSymlink, .brokenSymlink:
            do {
                try fileManager.removeItem(at: installCommandURL)
            } catch {
                throw CommandLineToolInstallError.installFailed(reason: error.localizedDescription)
            }
        case .missing:
            break
        }

        do {
            try fileManager.createSymbolicLink(
                at: installCommandURL,
                withDestinationURL: sourceCommandURL
            )
        } catch {
            throw CommandLineToolInstallError.installFailed(reason: error.localizedDescription)
        }

        return status()
    }

    private func activeCommandPath(pathDirectories: [URL], sourcePath: String) -> String? {
        for directory in pathDirectories {
            let candidate = directory.appendingPathComponent(Self.commandName, isDirectory: false)
            if pathEntry(at: candidate).resolvesTo(path: sourcePath) {
                return candidate.path
            }
            if pathEntry(at: candidate).isPresent {
                return nil
            }
        }

        return nil
    }

    private func shadowingCommandPath(pathDirectories: [URL], sourcePath: String) -> String? {
        for directory in pathDirectories {
            let candidate = directory.appendingPathComponent(Self.commandName, isDirectory: false)
            let entry = pathEntry(at: candidate)
            if entry.resolvesTo(path: sourcePath) {
                return nil
            }
            if entry.isPresent {
                return candidate.path
            }
        }

        return nil
    }

    private func managedCommandURL(sourcePath: String, candidateDirectories: [URL]) -> URL? {
        candidateDirectories
            .map { $0.appendingPathComponent(Self.commandName, isDirectory: false) }
            .first { pathEntry(at: $0).resolvesTo(path: sourcePath) }
    }

    private func resolvedInstallCommandURL(pathDirectories: [URL]) -> URL? {
        let installDirectory = candidateDirectories(pathDirectories: pathDirectories)
            .first(where: isWritableInstallDirectory)
        return installDirectory?.appendingPathComponent(Self.commandName, isDirectory: false)
    }

    private func candidateDirectories(pathDirectories: [URL]) -> [URL] {
        let combined = preferredInstallDirectories + pathDirectories
        var seen = Set<String>()
        var result: [URL] = []

        for directory in combined {
            let normalizedPath = directory.standardizedFileURL.path
            guard seen.insert(normalizedPath).inserted else { continue }
            result.append(directory)
        }

        return result
    }

    private func resolvedPathDirectories() -> [URL] {
        let rawPath = environment["PATH"] ?? ""
        return
            rawPath
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map {
                URL(
                    fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                    isDirectory: true
                )
                .standardizedFileURL
            }
    }

    private func isWritableInstallDirectory(_ directory: URL) -> Bool {
        guard let existingAncestor = nearestExistingAncestor(of: directory) else {
            return false
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: existingAncestor.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return false
        }

        return fileManager.isWritableFile(atPath: existingAncestor.path)
    }

    private func nearestExistingAncestor(of directory: URL) -> URL? {
        var current = directory.standardizedFileURL

        while true {
            if fileManager.fileExists(atPath: current.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func normalizePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func makeSetupCommand(
        sourceCommandURL: URL,
        installCommandURL: URL,
        prependToPath: Bool
    ) -> String {
        let installDirectory = installCommandURL.deletingLastPathComponent()
        let installDirectoryQuoted = shellQuote(installDirectory.path)
        let sourceCommandQuoted = shellQuote(sourceCommandURL.path)
        let installCommandQuoted = shellQuote(installCommandURL.path)

        var command = "mkdir -p \(installDirectoryQuoted) && ln -sfn \(sourceCommandQuoted) \(installCommandQuoted)"
        if prependToPath {
            command += " && export PATH=\(installDirectoryQuoted):\"$PATH\""
        }
        return command
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func pathEntry(at url: URL) -> PathEntry {
        var fileStatus = stat()
        if lstat(url.path, &fileStatus) != 0 {
            return .missing
        }

        let fileType = fileStatus.st_mode & S_IFMT
        guard fileType == S_IFLNK else {
            return .file
        }

        guard let rawDestination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return .brokenSymlink
        }

        let destinationURL = URL(
            fileURLWithPath: rawDestination,
            relativeTo: url.deletingLastPathComponent()
        )
        .standardizedFileURL

        if fileManager.fileExists(atPath: destinationURL.path) {
            return .otherSymlink(existingTargetPath: normalizePath(destinationURL))
        }

        return .brokenSymlink
    }

    private static func defaultPreferredInstallDirectories(homeDirectoryURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectoryURL
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true),
            homeDirectoryURL.appendingPathComponent("bin", isDirectory: true),
        ]
    }

    private static func defaultSourceCommandURL(fileManager: FileManager) -> URL? {
        let bundleURL = Bundle.main.bundleURL
        let executableURL = Bundle.main.executableURL

        let candidates = [
            bundleURL.pathExtension == "app"
                ? bundleURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("MacOS", isDirectory: true)
                    .appendingPathComponent(commandName, isDirectory: false)
                : nil,
            executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(commandName, isDirectory: false),
        ]
        .compactMap { $0 }

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private enum PathEntry {
        case missing
        case otherSymlink(existingTargetPath: String?)
        case brokenSymlink
        case file

        var isPresent: Bool {
            switch self {
            case .missing:
                return false
            case .otherSymlink, .brokenSymlink, .file:
                return true
            }
        }

        func resolvesTo(path sourcePath: String) -> Bool {
            switch self {
            case .otherSymlink(let existingTargetPath):
                return existingTargetPath == sourcePath
            case .missing, .brokenSymlink, .file:
                return false
            }
        }
    }
}
