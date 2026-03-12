//
//  LumeValidatedBaseService.swift
//  WorkspaceManagerCore
//
//  Canonical validated-base manifest and storage management for Lume.
//

import Foundation

public enum LumeValidatedBaseState: String, Codable, Sendable, Equatable {
    case missing
    case preparing
    case invalid
    case ready
}

public struct LumeValidatedBaseManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let vmName: String
    public let hostProfileKey: String
    public let storagePath: String
    public let sourceKind: LumeBaseVMSourceKind?
    public let imageReference: String?
    public let unattendedConfig: String?
    public let state: LumeValidatedBaseState
    public let validatedAt: String?
    public let failureStage: String?
    public let failureMessage: String?
    public let validationSource: String

    public init(
        schemaVersion: Int = LumeValidatedBaseManifest.schemaVersion,
        vmName: String,
        hostProfileKey: String,
        storagePath: String,
        sourceKind: LumeBaseVMSourceKind?,
        imageReference: String?,
        unattendedConfig: String? = nil,
        state: LumeValidatedBaseState,
        validatedAt: String?,
        failureStage: String?,
        failureMessage: String?,
        validationSource: String
    ) {
        self.schemaVersion = schemaVersion
        self.vmName = vmName
        self.hostProfileKey = hostProfileKey
        self.storagePath = storagePath
        self.sourceKind = sourceKind
        self.imageReference = imageReference
        self.unattendedConfig = unattendedConfig
        self.state = state
        self.validatedAt = validatedAt
        self.failureStage = failureStage
        self.failureMessage = failureMessage
        self.validationSource = validationSource
    }
}

public actor LumeValidatedBaseService {
    public static let shared = LumeValidatedBaseService()

    private let fileManager: FileManager
    private let manifestDirectoryURL: URL
    private let storageRootURL: URL

    public init(
        fileManager: FileManager = .default,
        manifestDirectoryURL: URL? = nil,
        storageRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.manifestDirectoryURL =
            manifestDirectoryURL
            ?? Self.defaultManifestDirectoryURL(fileManager: fileManager)
        self.storageRootURL =
            storageRootURL
            ?? Self.defaultStorageRootURL(fileManager: fileManager)
    }

    public func resolveBaseVMProfile(
        hostProfile: LumeHostProfile,
        imageResolution: LumeImageResolution?
    ) -> LumeBaseVMProfile {
        let baseIdentifier = Self.sanitizeNameComponent(hostProfile.profileKey)
        if let imageResolution {
            return LumeBaseVMProfile(
                vmName: "workspaces-validated-base-macos-\(baseIdentifier)",
                profileKey: hostProfile.profileKey,
                displayName: imageResolution.profileDisplayName,
                imageReference: imageResolution.entry.imageReference,
                preferredSourceKind: .pulledImage,
                storagePath: validatedBaseStorageDirectoryURL.path
            )
        }

        return LumeBaseVMProfile(
            vmName: "workspaces-validated-base-macos-\(baseIdentifier)",
            profileKey: hostProfile.profileKey,
            displayName: "\(hostProfile.displayName) (stock macOS base)",
            imageReference: nil,
            preferredSourceKind: .stockPrepared,
            storagePath: validatedBaseStorageDirectoryURL.path
        )
    }

    public func loadManifest(named vmName: String) -> LumeValidatedBaseManifest? {
        let manifestURL = manifestDirectoryURL.appendingPathComponent("\(vmName).json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(LumeValidatedBaseManifest.self, from: data)
    }

    public func saveManifest(_ manifest: LumeValidatedBaseManifest) throws {
        try fileManager.createDirectory(at: manifestDirectoryURL, withIntermediateDirectories: true)
        let manifestURL = manifestDirectoryURL.appendingPathComponent("\(manifest.vmName).json", isDirectory: false)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func deleteManifest(named vmName: String) {
        let manifestURL = manifestDirectoryURL.appendingPathComponent("\(vmName).json", isDirectory: false)
        try? fileManager.removeItem(at: manifestURL)
    }

    public func validationReason(
        for manifest: LumeValidatedBaseManifest?,
        expectedProfileKey: String
    ) -> String? {
        guard let manifest else {
            return "The validated base macOS VM exists, but it has not passed standalone Lume validation yet."
        }

        guard manifest.schemaVersion == LumeValidatedBaseManifest.schemaVersion else {
            return "The validated base macOS VM manifest schema is unsupported."
        }

        guard manifest.state == .ready else {
            if let failureMessage = manifest.failureMessage, !failureMessage.isEmpty {
                return failureMessage
            }
            return "The validated base macOS VM is present, but standalone validation has not marked it ready."
        }

        guard manifest.hostProfileKey == expectedProfileKey else {
            return "The validated base macOS VM was prepared for \(manifest.hostProfileKey), not \(expectedProfileKey)."
        }

        guard manifest.validatedAt?.isEmpty == false else {
            return "The validated base macOS VM manifest is missing its verification timestamp."
        }

        return nil
    }

    public func vmDirectoryExists(vmName: String, storagePath: String) -> Bool {
        let directPath = URL(fileURLWithPath: storagePath, isDirectory: true)
            .appendingPathComponent(vmName, isDirectory: true)
        return fileManager.fileExists(atPath: directPath.path)
    }

    public var validatedBaseStorageDirectoryURL: URL {
        storageRootURL.appendingPathComponent("validated-bases", isDirectory: true)
    }

    public var workspaceVMStorageDirectoryURL: URL {
        storageRootURL.appendingPathComponent("workspace-vms", isDirectory: true)
    }

    public var standaloneSmokeStorageDirectoryURL: URL {
        storageRootURL.appendingPathComponent("standalone-smoke", isDirectory: true)
    }

    public nonisolated static func defaultManifestDirectoryURL(fileManager: FileManager) -> URL {
        if let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return
                applicationSupportDirectory
                .appendingPathComponent("WorkspaceManager", isDirectory: true)
                .appendingPathComponent("LumeValidatedBases", isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".workspacemanager", isDirectory: true)
            .appendingPathComponent("lume-validated-bases", isDirectory: true)
    }

    public nonisolated static func defaultStorageRootURL(fileManager: FileManager) -> URL {
        if let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return
                applicationSupportDirectory
                .appendingPathComponent("WorkspaceManager", isDirectory: true)
                .appendingPathComponent("LumeStorage", isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".workspacemanager", isDirectory: true)
            .appendingPathComponent("lume-storage", isDirectory: true)
    }

    public nonisolated static func sanitizeNameComponent(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let lowercased = rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        let sanitizedScalars = lowercased.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }

        let collapsed = String(sanitizedScalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "base" : collapsed
    }
}
