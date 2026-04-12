import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("LumeValidatedBaseService")
struct LumeValidatedBaseServiceTests {
    @Test("Resolves validated base profile into isolated storage")
    func resolvesValidatedBaseProfile() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-validated-base-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = LumeValidatedBaseService(
            manifestDirectoryURL: tempRoot.appendingPathComponent("manifests", isDirectory: true),
            storageRootURL: tempRoot.appendingPathComponent("storage", isDirectory: true)
        )
        let hostProfile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .tahoe,
            macOSVersion: "26.2",
            xcodeVersion: "26.2",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )
        let imageResolution = try LumeImageCatalog.default.resolveDefaultMacOSImage(for: hostProfile)

        let baseProfile = await service.resolveBaseVMProfile(
            hostProfile: hostProfile,
            imageResolution: imageResolution
        )

        #expect(baseProfile.vmName == "workspaces-validated-base-macos-tahoe-26-2-xcode-26-2")
        #expect(baseProfile.preferredSourceKind == .pulledImage)
        #expect(
            baseProfile.storagePath
                == tempRoot.appendingPathComponent("storage/validated-bases", isDirectory: true).path
        )
    }

    @Test("Validation reason requires a ready manifest for the same host profile")
    func validationReason() async {
        let service = LumeValidatedBaseService(
            manifestDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            ),
            storageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        )

        let readyManifest = LumeValidatedBaseManifest(
            vmName: "workspaces-validated-base-macos-tahoe-26-2-xcode-26-2",
            hostProfileKey: "tahoe-26.2-xcode-26.2",
            storagePath: "/tmp/lume-storage/validated-bases",
            sourceKind: .pulledImage,
            imageReference: "macos-tahoe-xcode:26.2",
            unattendedConfig: "config/lume/unattended/tahoe-workspaces-v1.yml",
            state: .ready,
            validatedAt: "2026-03-09T19:30:00Z",
            failureStage: nil,
            failureMessage: nil,
            validationSource: "standalone-lume-validation"
        )

        let matchingReason = await service.validationReason(
            for: readyManifest,
            expectedProfileKey: "tahoe-26.2-xcode-26.2"
        )
        #expect(matchingReason == nil)

        let mismatchedReason = await service.validationReason(
            for: readyManifest,
            expectedProfileKey: "sequoia-15.1-xcode-16.4"
        )
        #expect(mismatchedReason?.contains("not sequoia-15.1-xcode-16.4") == true)

        let invalidManifest = LumeValidatedBaseManifest(
            vmName: readyManifest.vmName,
            hostProfileKey: readyManifest.hostProfileKey,
            storagePath: readyManifest.storagePath,
            sourceKind: readyManifest.sourceKind,
            imageReference: readyManifest.imageReference,
            unattendedConfig: readyManifest.unattendedConfig,
            state: .invalid,
            validatedAt: nil,
            failureStage: "clone-smoke",
            failureMessage: "Clone did not reach SSH.",
            validationSource: readyManifest.validationSource
        )
        let invalidReason = await service.validationReason(
            for: invalidManifest,
            expectedProfileKey: readyManifest.hostProfileKey
        )
        #expect(invalidReason == "Clone did not reach SSH.")
    }

    @Test("VM directory existence uses the isolated storage path")
    func vmDirectoryExists() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-validated-base-vm-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storagePath = tempRoot.appendingPathComponent("storage/validated-bases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storagePath.appendingPathComponent("workspaces-validated-base-macos-tahoe", isDirectory: true),
            withIntermediateDirectories: true
        )

        let service = LumeValidatedBaseService(
            manifestDirectoryURL: tempRoot.appendingPathComponent("manifests", isDirectory: true),
            storageRootURL: tempRoot.appendingPathComponent("storage", isDirectory: true)
        )

        let exists = await service.vmDirectoryExists(
            vmName: "workspaces-validated-base-macos-tahoe",
            storagePath: storagePath.path
        )
        let missing = await service.vmDirectoryExists(
            vmName: "workspaces-validated-base-macos-missing",
            storagePath: storagePath.path
        )

        #expect(exists)
        #expect(!missing)
    }

    @Test("Save and load preserves unattended config metadata")
    func saveAndLoadManifest() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-validated-base-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = LumeValidatedBaseService(
            manifestDirectoryURL: tempRoot.appendingPathComponent("manifests", isDirectory: true),
            storageRootURL: tempRoot.appendingPathComponent("storage", isDirectory: true)
        )

        let manifest = LumeValidatedBaseManifest(
            vmName: "workspaces-validated-base-macos-tahoe-26-2-xcode-26-2",
            hostProfileKey: "tahoe-26.2-xcode-26.2",
            storagePath: "/tmp/lume-storage/validated-bases",
            sourceKind: .stockPrepared,
            imageReference: nil,
            unattendedConfig: "config/lume/unattended/tahoe-workspaces-v1.yml",
            state: .invalid,
            validatedAt: nil,
            failureStage: "prepare-base",
            failureMessage: "Timed out on Screen Time.",
            validationSource: "standalone-lume-validation"
        )

        try await service.saveManifest(manifest)
        let loadedManifest = await service.loadManifest(named: manifest.vmName)

        #expect(loadedManifest == manifest)
    }

    @Test("Deleting one manifest leaves sibling manifests intact")
    func deleteManifestDeletesOnlyRequestedManifest() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lume-validated-base-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let manifestDirectory = tempRoot.appendingPathComponent("manifests", isDirectory: true)
        let service = LumeValidatedBaseService(
            manifestDirectoryURL: manifestDirectory,
            storageRootURL: tempRoot.appendingPathComponent("storage", isDirectory: true)
        )

        let first = LumeValidatedBaseManifest(
            vmName: "workspaces-validated-base-one",
            hostProfileKey: "tahoe-26.2-xcode-26.2",
            storagePath: "/tmp/lume-storage/validated-bases",
            sourceKind: .pulledImage,
            imageReference: "macos-tahoe-xcode:26.2",
            unattendedConfig: nil,
            state: .ready,
            validatedAt: "2026-03-11T20:00:00Z",
            failureStage: nil,
            failureMessage: nil,
            validationSource: "standalone-lume-validation"
        )
        let second = LumeValidatedBaseManifest(
            vmName: "workspaces-validated-base-two",
            hostProfileKey: first.hostProfileKey,
            storagePath: first.storagePath,
            sourceKind: first.sourceKind,
            imageReference: first.imageReference,
            unattendedConfig: first.unattendedConfig,
            state: first.state,
            validatedAt: first.validatedAt,
            failureStage: first.failureStage,
            failureMessage: first.failureMessage,
            validationSource: first.validationSource
        )

        try await service.saveManifest(first)
        try await service.saveManifest(second)

        await service.deleteManifest(named: first.vmName)

        #expect(await service.loadManifest(named: first.vmName) == nil)
        #expect(await service.loadManifest(named: second.vmName) == second)
    }
}
