import AppKit
import Foundation
import Sparkle
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

    @Test("Updater delegate exposes Sparkle update-check gate selector")
    @MainActor
    func updaterDelegateExposesSparkleUpdateCheckGateSelector() {
        let delegate = SoftwareUpdateDelegate()

        #expect(delegate.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
    }

    @Test("Manual update check asks for disclosure before Sparkle may check")
    @MainActor
    func manualUpdateCheckAsksForDisclosureBeforeSparkleMayCheck() {
        let suiteName = "SoftwareUpdatePrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var promptCount = 0
        let controller = SoftwareUpdateController(
            startUpdater: false,
            userDefaults: defaults,
            manualCheckDisclosurePresenter: {
                promptCount += 1
                return false
            }
        )

        #expect(controller.shouldAllowSparkleUpdateCheck(.updates) == false)
        #expect(promptCount == 1)
        #expect(defaults.bool(forKey: SoftwareUpdateConstants.manualCheckDisclosureAcceptedKey) == false)
    }

    @Test("Check for Updates menu item is routed through disclosure gate")
    @MainActor
    func checkForUpdatesMenuItemIsRoutedThroughDisclosureGate() {
        let suiteName = "SoftwareUpdatePrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var promptCount = 0
        let controller = SoftwareUpdateController(
            startUpdater: false,
            userDefaults: defaults,
            manualCheckDisclosurePresenter: {
                promptCount += 1
                return false
            }
        )

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "WorkSpaces")
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: NSSelectorFromString("checkForUpdates:"),
            keyEquivalent: ""
        )
        appMenu.addItem(checkForUpdatesItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        controller.installCheckForUpdatesMenuItem(in: mainMenu)

        #expect(checkForUpdatesItem.target === controller)
        #expect(checkForUpdatesItem.action == NSSelectorFromString("checkForUpdatesMenuItem:"))

        _ = controller.perform(NSSelectorFromString("checkForUpdatesMenuItem:"), with: checkForUpdatesItem)

        #expect(promptCount == 1)
        #expect(defaults.bool(forKey: SoftwareUpdateConstants.manualCheckDisclosureAcceptedKey) == false)
    }

    @Test("Manual disclosure confirmation is remembered")
    @MainActor
    func manualDisclosureConfirmationIsRemembered() {
        let suiteName = "SoftwareUpdatePrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var promptCount = 0
        let controller = SoftwareUpdateController(
            startUpdater: false,
            userDefaults: defaults,
            manualCheckDisclosurePresenter: {
                promptCount += 1
                return true
            }
        )

        #expect(controller.shouldAllowSparkleUpdateCheck(.updates) == true)
        #expect(controller.shouldAllowSparkleUpdateCheck(.updates) == true)
        #expect(promptCount == 1)
        #expect(defaults.bool(forKey: SoftwareUpdateConstants.manualCheckDisclosureAcceptedKey) == true)
    }
}
