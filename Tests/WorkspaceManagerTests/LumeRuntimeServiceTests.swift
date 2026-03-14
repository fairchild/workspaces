import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("LumeRuntimeService")
struct LumeRuntimeServiceTests {
    private let imageCatalog = LumeImageCatalog.default

    @Test("Host profile parsing detects Tahoe and Xcode")
    func hostProfileParsing() throws {
        let profile = try LumeHostProfile.parse(
            architecture: "arm64",
            swVersOutput: "26.2",
            xcodebuildOutput: "Xcode 26.2\nBuild version 17C5036g\n",
            developerDirectoryOutput: "/Applications/Xcode.app/Contents/Developer\n"
        )

        #expect(profile.macOSFamily == .tahoe)
        #expect(profile.macOSVersion == "26.2")
        #expect(profile.xcodeVersion == "26.2")
        #expect(profile.profileKey == "tahoe-26.2-xcode-26.2")
        #expect(profile.displayName == "Tahoe 26.2 + Xcode 26.2")
    }

    @Test("Default macOS image resolution prefers exact match")
    func defaultImageResolutionPrefersExactMatch() throws {
        let profile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .tahoe,
            macOSVersion: "26.2",
            xcodeVersion: "26.2",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )

        let resolution = try imageCatalog.resolveDefaultMacOSImage(for: profile)

        #expect(resolution.matchKind == .exact)
        #expect(resolution.entry.imageReference == "macos-tahoe-xcode:26.2")
        #expect(resolution.profileDisplayName == "macOS Tahoe 26.2 + Xcode 26.2")
    }

    @Test("Default macOS image resolution falls back to nearest same family")
    func defaultImageResolutionFallsBackToNearestSameFamily() throws {
        let profile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .tahoe,
            macOSVersion: "26.3",
            xcodeVersion: "26.1",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )

        let resolution = try imageCatalog.resolveDefaultMacOSImage(for: profile)

        #expect(resolution.matchKind == .nearestSameFamily)
        #expect(resolution.entry.imageReference == "macos-tahoe-xcode:26.2")
    }

    @Test("Default macOS image resolution fails when the macOS family is unsupported")
    func defaultImageResolutionFailsWithoutSameFamilyImage() {
        let profile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .sonoma,
            macOSVersion: "14.7",
            xcodeVersion: "15.4",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )

        do {
            _ = try imageCatalog.resolveDefaultMacOSImage(for: profile)
            Issue.record("Expected image resolution to fail for an unsupported macOS family.")
        } catch {
            #expect(error.localizedDescription.contains("Choose Linux VM instead"))
        }
    }

    @Test("Base VM profile uses image reference when a golden image match exists")
    func baseVMProfileUsesImageReferenceWhenImageExists() throws {
        let profile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .tahoe,
            macOSVersion: "26.2",
            xcodeVersion: "26.2",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )
        let resolution = try imageCatalog.resolveDefaultMacOSImage(for: profile)

        let baseProfile = LumeValidatedBaseService.resolveBaseVMProfile(
            hostProfile: profile,
            imageResolution: resolution
        )

        #expect(baseProfile.vmName == "workspaces-validated-base-macos-tahoe-26-2-xcode-26-2")
        #expect(baseProfile.imageReference == "macos-tahoe-xcode:26.2")
        #expect(baseProfile.preferredSourceKind == .pulledImage)
        #expect(baseProfile.storagePath.hasSuffix("/WorkspaceManager/LumeStorage/validated-bases"))
    }

    @Test("Base VM profile falls back to host profile when no golden image exists")
    func baseVMProfileFallsBackToHostProfileWithoutGoldenImage() {
        let profile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .sonoma,
            macOSVersion: "14.7",
            xcodeVersion: "15.4",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )

        let baseProfile = LumeValidatedBaseService.resolveBaseVMProfile(
            hostProfile: profile,
            imageResolution: nil
        )

        #expect(baseProfile.vmName == "workspaces-validated-base-macos-sonoma-14-7-xcode-15-4")
        #expect(baseProfile.imageReference == nil)
        #expect(baseProfile.preferredSourceKind == .stockPrepared)
        #expect(baseProfile.storagePath.hasSuffix("/WorkspaceManager/LumeStorage/validated-bases"))
    }
}
