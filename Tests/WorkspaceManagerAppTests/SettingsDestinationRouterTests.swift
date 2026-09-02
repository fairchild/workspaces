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

@MainActor
@Suite("SettingsSectionScroller")
struct SettingsSectionScrollerTests {
    /// Records what the scroller asked for, and what the router still held at
    /// the moment of each attempt.
    private final class Recorder {
        var scrolled: [SettingsSection] = []
        var pendingAtEachAttempt: [SettingsSection?] = []
    }

    private func scroller(
        attempts: Int,
        router: SettingsDestinationRouter,
        recorder: Recorder
    ) -> SettingsSectionScroller {
        SettingsSectionScroller(
            attempts: attempts,
            delay: .zero,
            sleep: { _ in },
            scrollTo: { section in
                recorder.scrolled.append(section)
                recorder.pendingAtEachAttempt.append(router.pendingSection)
            }
        )
    }

    @Test("Scrolls to the requested section and then clears the request")
    func scrollsThenClears() async {
        let router = SettingsDestinationRouter(pendingSection: .agents)
        let recorder = Recorder()

        await scroller(attempts: 1, router: router, recorder: recorder).run(router)

        #expect(recorder.scrolled == [.agents])
        #expect(router.pendingSection == nil)
    }

    @Test("Retries, because a scroll before the Form registers its anchors silently does nothing")
    func retriesUntilAttemptsAreSpent() async {
        let router = SettingsDestinationRouter(pendingSection: .agents)
        let recorder = Recorder()

        await scroller(attempts: 3, router: router, recorder: recorder).run(router)

        #expect(recorder.scrolled == [.agents, .agents, .agents])
    }

    @Test("The request survives every attempt, so a no-op scroll gets another go")
    func requestSurvivesUntilTheAttemptsAreSpent() async {
        let router = SettingsDestinationRouter(pendingSection: .agents)
        let recorder = Recorder()

        await scroller(attempts: 3, router: router, recorder: recorder).run(router)

        #expect(recorder.pendingAtEachAttempt == [.agents, .agents, .agents])
        #expect(router.pendingSection == nil)
    }

    @Test("Nothing pending means no scroll at all — Settings opens where the user left it")
    func doesNothingWithoutARequest() async {
        let router = SettingsDestinationRouter()
        let recorder = Recorder()

        await scroller(attempts: 3, router: router, recorder: recorder).run(router)

        #expect(recorder.scrolled.isEmpty)
        #expect(router.pendingSection == nil)
    }

    @Test("A request cleared mid-run stops the retry instead of scrolling on")
    func stopsWhenTheRequestIsClearedMidRun() async {
        let router = SettingsDestinationRouter(pendingSection: .agents)
        let recorder = Recorder()
        let scroller = SettingsSectionScroller(
            attempts: 3,
            delay: .zero,
            sleep: { _ in },
            scrollTo: { section in
                recorder.scrolled.append(section)
                router.consumePendingSection()
            }
        )

        await scroller.run(router)

        #expect(recorder.scrolled == [.agents])
    }

    @Test("A zero or negative attempt count still tries once rather than never")
    func alwaysAttemptsAtLeastOnce() async {
        let router = SettingsDestinationRouter(pendingSection: .agents)
        let recorder = Recorder()

        await scroller(attempts: 0, router: router, recorder: recorder).run(router)

        #expect(recorder.scrolled == [.agents])
        #expect(router.pendingSection == nil)
    }

    @Test("The shipped defaults retry more than once, and wait between tries")
    func defaultsAllowForALateAnchor() {
        #expect(SettingsSectionScroller.defaultAttempts > 1)
        #expect(SettingsSectionScroller.defaultDelay > .zero)
    }
}
