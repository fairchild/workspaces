//
//  SoftwareUpdateController.swift
//  WorkspaceManager
//
//  Privacy-first Sparkle update integration.
//

import AppKit
import Combine
import Foundation
import Sparkle

enum SoftwareUpdateConstants {
    static let feedURLString = "https://github.com/fairchild/workspaces/releases/latest/download/appcast.xml"
    static let manualCheckDisclosureAcceptedKey = "softwareUpdateManualCheckDisclosureAccepted"
    static let automaticCheckDisclosure =
        "When enabled, WorkSpaces periodically contacts GitHub Releases to check for a signed appcast. WorkSpaces does not send telemetry, system profile information, or custom tracking parameters. GitHub may receive normal HTTP request metadata such as your IP address."
    static let manualCheckDisclosure =
        "WorkSpaces will contact GitHub Releases to check for a signed appcast. WorkSpaces does not send telemetry, system profile information, or custom tracking parameters. GitHub may receive normal HTTP request metadata such as your IP address."
}

enum SoftwareUpdatePrivacyPolicy {
    static let shouldPromptForAutomaticCheckPermission = false
    static let feedParameters: [[String: String]] = []
    static let allowedSystemProfileKeys: [String] = []
}

@MainActor
private protocol SoftwareUpdateCheckGate: AnyObject {
    func shouldAllowSparkleUpdateCheck(_ updateCheck: SPUUpdateCheck) -> Bool
}

@MainActor
final class SoftwareUpdateDelegate: NSObject, SPUUpdaterDelegate {
    fileprivate weak var checkGate: SoftwareUpdateCheckGate?

    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard checkGate?.shouldAllowSparkleUpdateCheck(updateCheck) ?? true else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        SoftwareUpdatePrivacyPolicy.shouldPromptForAutomaticCheckPermission
    }

    func feedParameters(
        for updater: SPUUpdater,
        sendingSystemProfile sendingProfile: Bool
    ) -> [[String: String]] {
        SoftwareUpdatePrivacyPolicy.feedParameters
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        SoftwareUpdatePrivacyPolicy.allowedSystemProfileKeys
    }
}

@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject, NSMenuItemValidation, SoftwareUpdateCheckGate {
    @Published private(set) var canCheckForUpdates = false

    private static let checkForUpdatesMenuTitle = "Check for Updates..."

    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate: SoftwareUpdateDelegate
    private let userDefaults: UserDefaults
    private let manualCheckDisclosurePresenter: @MainActor () -> Bool
    private var canCheckForUpdatesCancellable: AnyCancellable?

    var updater: SPUUpdater {
        updaterController.updater
    }

    init(
        startUpdater: Bool = true,
        userDefaults: UserDefaults = .standard,
        manualCheckDisclosurePresenter: @escaping @MainActor () -> Bool = SoftwareUpdateController
            .presentManualCheckDisclosure
    ) {
        self.updaterDelegate = SoftwareUpdateDelegate()
        self.userDefaults = userDefaults
        self.manualCheckDisclosurePresenter = manualCheckDisclosurePresenter
        let shouldStartUpdater = startUpdater && Self.isSparkleConfigured()
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: shouldStartUpdater,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        super.init()
        self.updaterDelegate.checkGate = self
        self.canCheckForUpdates = updaterController.updater.canCheckForUpdates
        self.canCheckForUpdatesCancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
                self?.installCheckForUpdatesMenuItem()
            }
    }

    static func isSparkleConfigured(bundle: Bundle = .main) -> Bool {
        guard let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }
        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func checkForUpdatesWithDisclosure() {
        guard confirmManualCheckDisclosureIfNeeded() else { return }
        updater.checkForUpdates()
    }

    func installCheckForUpdatesMenuItem() {
        installCheckForUpdatesMenuItem(in: NSApp.mainMenu)
    }

    func installCheckForUpdatesMenuItem(in menu: NSMenu?) {
        guard let appMenu = menu?.items.first?.submenu else { return }

        for item in appMenu.items where item.title == Self.checkForUpdatesMenuTitle {
            item.target = self
            item.action = #selector(checkForUpdatesMenuItem(_:))
            item.isEnabled = canCheckForUpdates
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdatesMenuItem(_:)) else {
            return true
        }
        return canCheckForUpdates
    }

    @objc private func checkForUpdatesMenuItem(_ sender: Any?) {
        checkForUpdatesWithDisclosure()
    }

    func shouldAllowSparkleUpdateCheck(_ updateCheck: SPUUpdateCheck) -> Bool {
        guard updateCheck == .updates else {
            return true
        }
        return confirmManualCheckDisclosureIfNeeded()
    }

    func confirmManualCheckDisclosureIfNeeded() -> Bool {
        if userDefaults.bool(forKey: SoftwareUpdateConstants.manualCheckDisclosureAcceptedKey) {
            return true
        }

        guard manualCheckDisclosurePresenter() else { return false }
        userDefaults.set(true, forKey: SoftwareUpdateConstants.manualCheckDisclosureAcceptedKey)
        return true
    }

    private static func presentManualCheckDisclosure() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Check for WorkSpaces Updates?"
        alert.informativeText = SoftwareUpdateConstants.manualCheckDisclosure
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Check for Updates")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
