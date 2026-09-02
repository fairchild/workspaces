import Testing

@testable import WorkspaceManager

@MainActor
@Suite("SettingsDestinationRouter")
struct SettingsDestinationRouterTests {
    @Test("A fresh router has nothing pending, so Settings opens where the user left it")
    func startsEmpty() {
        let router = SettingsDestinationRouter()

        #expect(router.pendingSection == nil)
        #expect(router.consumePendingSection() == nil)
    }

    @Test("A requested section is what the next appearance consumes")
    func requestIsConsumed() {
        let router = SettingsDestinationRouter()

        router.request(.agents)

        #expect(router.pendingSection == .agents)
        #expect(router.consumePendingSection() == .agents)
    }

    @Test("Consuming clears the request, so reopening Settings does not re-scroll")
    func consumeIsOneShot() {
        let router = SettingsDestinationRouter(pendingSection: .agents)

        #expect(router.consumePendingSection() == .agents)
        #expect(router.pendingSection == nil)
        #expect(router.consumePendingSection() == nil)
    }

    @Test("A second request before the first is consumed leaves one destination, not two")
    func requestsCollapse() {
        let router = SettingsDestinationRouter()

        router.request(.agents)
        router.request(.agents)

        #expect(router.consumePendingSection() == .agents)
        #expect(router.consumePendingSection() == nil)
    }

    @Test("Every section's anchor id is its raw value, so the anchor cannot drift")
    func anchorMatchesRawValue() {
        for section in SettingsSection.allCases {
            #expect(section.id == section.rawValue)
        }
        #expect(SettingsSection.agents.id == "agents")
    }
}
