import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("NewWorkspaceSheet")
struct NewWorkspaceSheetTests {
    @Test("Environment option identity uses provider and guest OS")
    func environmentOptionIdentityUsesProviderAndGuestOS() {
        let localOption = makeOption(
            providerID: LocalWorkspaceProvider.identifier,
            guestOS: nil
        )
        let macOSLumeOption = makeOption(
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .macOS
        )

        #expect(localOption.id == LocalWorkspaceProvider.identifier)
        #expect(macOSLumeOption.id == "\(LumeWorkspaceProvider.identifier):macos")
    }

    @Test("Fixture mode prefers the macOS Lume option")
    func fixtureModePrefersMacOSLumeOption() {
        let options = [
            makeOption(providerID: LocalWorkspaceProvider.identifier, guestOS: nil),
            makeOption(providerID: DaytonaWorkspaceProvider.identifier, guestOS: .linux),
            makeOption(providerID: LumeWorkspaceProvider.identifier, guestOS: .macOS),
            makeOption(providerID: LumeWorkspaceProvider.identifier, guestOS: .linux),
        ]

        let preferredID = NewWorkspaceSheet.preferredInitialEnvironmentID(
            for: options,
            fixtureEnabled: true
        )

        #expect(preferredID == "\(LumeWorkspaceProvider.identifier):macos")
    }

    @Test("Non-fixture mode prefers the local option")
    func nonFixtureModePrefersLocalOption() {
        let options = [
            makeOption(providerID: DaytonaWorkspaceProvider.identifier, guestOS: .linux),
            makeOption(providerID: LocalWorkspaceProvider.identifier, guestOS: nil),
            makeOption(providerID: LumeWorkspaceProvider.identifier, guestOS: .macOS),
        ]

        let preferredID = NewWorkspaceSheet.preferredInitialEnvironmentID(
            for: options,
            fixtureEnabled: false
        )

        #expect(preferredID == LocalWorkspaceProvider.identifier)
    }

    @Test("Preferred selection falls back to the first available option")
    func preferredSelectionFallsBackToFirstAvailableOption() {
        let unavailableLocal = makeOption(
            providerID: LocalWorkspaceProvider.identifier,
            guestOS: nil,
            isAvailable: false
        )
        let firstAvailable = makeOption(
            providerID: DaytonaWorkspaceProvider.identifier,
            guestOS: .linux
        )
        let options = [
            unavailableLocal,
            firstAvailable,
            makeOption(providerID: LumeWorkspaceProvider.identifier, guestOS: .linux),
        ]

        let preferredID = NewWorkspaceSheet.preferredInitialEnvironmentID(
            for: options,
            fixtureEnabled: false
        )

        #expect(preferredID == firstAvailable.id)
    }

    private func makeOption(
        providerID: String,
        guestOS: WorkspaceGuestOS?,
        isAvailable: Bool = true
    ) -> WorkspaceEnvironmentSheetOption {
        WorkspaceEnvironmentSheetOption(
            title: "Option",
            subtitle: "Subtitle",
            description: "Description",
            iconName: "terminal",
            providerID: providerID,
            guestOS: guestOS,
            isAvailable: isAvailable,
            statusText: nil,
            availabilityReason: isAvailable ? nil : "Unavailable"
        )
    }
}
