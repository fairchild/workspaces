import Foundation
import Testing

@testable import WorkspaceManager

@Suite("SoftwareUpdatePrivacy")
struct SoftwareUpdatePrivacyTests {
    @Test("Sparkle plist defaults are privacy preserving")
    func sparklePlistDefaultsArePrivacyPreserving() throws {
        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/WorkspaceManager/Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["SUFeedURL"] as? String == SoftwareUpdateConstants.feedURLString)
        #expect(plist["SUPublicEDKey"] as? String == "2iJCG30PnNC42c7NxxsMNFup+mnlKOU2/MZMEwm6lg4=")
        #expect(plist["SUScheduledCheckInterval"] as? Int == 604_800)
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
    }

    @Test("Updater delegate policy sends no telemetry")
    func updaterDelegatePolicySendsNoTelemetry() {
        #expect(SoftwareUpdatePrivacyPolicy.shouldPromptForAutomaticCheckPermission == false)
        #expect(SoftwareUpdatePrivacyPolicy.feedParameters.isEmpty)
        #expect(SoftwareUpdatePrivacyPolicy.allowedSystemProfileKeys.isEmpty)
    }
}
