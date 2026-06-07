//
//  GhosttyThemeStoreTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("GhosttyThemeStore")
struct GhosttyThemeStoreTests {
    /// Records every applied pair so tests can assert what reached the terminal.
    private final class ApplyRecorder {
        private(set) var applied: [(light: String, dark: String)] = []
        func record(_ light: String, _ dark: String) { applied.append((light, dark)) }
        var last: (light: String, dark: String)? { applied.last }
    }

    /// Zero debounce so previews apply inline — deterministic under parallel
    /// suite execution (a timed debounce flakes when the main actor is busy).
    private func makeStore() -> (store: GhosttyThemeStore, defaults: UserDefaults, recorder: ApplyRecorder) {
        let defaults = UserDefaults(suiteName: "GhosttyThemeStoreTests-\(UUID().uuidString)")!
        let recorder = ApplyRecorder()
        let store = GhosttyThemeStore(defaults: defaults, debounce: .zero) { light, dark in
            recorder.record(light, dark)
        }
        return (store, defaults, recorder)
    }

    @Test("Setting a slot persists it and applies the new pair")
    func setPersistsAndApplies() {
        let (store, defaults, recorder) = makeStore()

        store.setDarkTheme("Dracula")

        #expect(store.darkTheme == "Dracula")
        #expect(GhosttyThemePersistence.load(from: defaults).darkTheme == "Dracula")
        #expect(recorder.last?.dark == "Dracula")
    }

    @Test("Initial values reflect previously persisted selection")
    func loadsPersistedSelection() {
        let defaults = UserDefaults(suiteName: "GhosttyThemeStoreTests-\(UUID().uuidString)")!
        GhosttyThemePersistence.save(
            GhosttyThemePersistence.Pair(lightTheme: "Catppuccin Latte", darkTheme: "Nord"),
            to: defaults
        )
        let store = GhosttyThemeStore(defaults: defaults) { _, _ in }

        #expect(store.lightTheme == "Catppuccin Latte")
        #expect(store.darkTheme == "Nord")
    }

    @Test("Preview applies live without persisting")
    func previewDoesNotPersist() {
        let (store, defaults, recorder) = makeStore()

        store.preview(lightTheme: "", darkTheme: "Nord")

        #expect(recorder.last?.dark == "Nord")
        #expect(GhosttyThemePersistence.load(from: defaults).darkTheme == "")
    }

    @Test("Ending a preview reverts to the committed pair")
    func endPreviewReverts() {
        let (store, _, recorder) = makeStore()

        store.setDarkTheme("Dracula")
        store.preview(lightTheme: "", darkTheme: "Nord")
        #expect(recorder.last?.dark == "Nord")

        store.endPreview()
        #expect(recorder.last?.dark == "Dracula")
        #expect(store.darkTheme == "Dracula")
    }

    @Test("Committing themes records them most-recent-first, deduped")
    func recordsRecentsMostRecentFirst() {
        let (store, defaults, _) = makeStore()

        store.setDarkTheme("Nord")
        store.setLightTheme("Catppuccin Latte")
        store.setDarkTheme("Dracula")
        store.setDarkTheme("Nord")  // re-use moves it to front, no duplicate

        #expect(store.recentThemes == ["Nord", "Dracula", "Catppuccin Latte"])
        #expect(GhosttyThemePersistence.loadRecents(from: defaults) == store.recentThemes)
    }

    @Test("The Ghostty Default (empty) selection is not recorded as a recent")
    func emptySelectionNotRecorded() {
        let (store, _, _) = makeStore()

        store.setDarkTheme("Dracula")
        store.setLightTheme("")  // clear the light slot

        #expect(store.recentThemes == ["Dracula"])
    }

    @Test("Recents are capped at the most recent eight")
    func recentsAreCapped() {
        let (store, _, _) = makeStore()

        for index in 1...10 {
            store.setDarkTheme("Theme \(index)")
        }

        #expect(store.recentThemes.count == 8)
        #expect(store.recentThemes.first == "Theme 10")
        #expect(store.recentThemes.last == "Theme 3")
        #expect(!store.recentThemes.contains("Theme 1"))
    }

    @Test("Recents reload from persistence in a new store")
    func recentsReloadFromPersistence() {
        let defaults = UserDefaults(suiteName: "GhosttyThemeStoreTests-\(UUID().uuidString)")!
        let first = GhosttyThemeStore(defaults: defaults, debounce: .zero) { _, _ in }
        first.setDarkTheme("Dracula")
        first.setLightTheme("Nord")

        let reloaded = GhosttyThemeStore(defaults: defaults, debounce: .zero) { _, _ in }
        #expect(reloaded.recentThemes == ["Nord", "Dracula"])
    }
}
