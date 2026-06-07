//
//  GhosttyThemeStore.swift
//  WorkspaceManager
//

import Foundation

/// Single backing store for the Terminal Theme, shared by the Settings pickers
/// and the Cmd+Shift+P command overlay.
///
/// Holds the committed light/dark pair (persisted in `UserDefaults`), drives the
/// live apply through `GhosttyAppManager`, and supports transient, debounced
/// previews that revert to the committed pair on demand.
@MainActor
final class GhosttyThemeStore: ObservableObject {
    static let shared = GhosttyThemeStore()

    /// Committed light theme name. Empty means "no selection" (Ghostty default).
    @Published private(set) var lightTheme: String
    /// Committed dark theme name. Empty means "no selection" (Ghostty default).
    @Published private(set) var darkTheme: String

    private let defaults: UserDefaults
    private let apply: @MainActor (_ light: String, _ dark: String) -> Void
    /// Debounce window for highlight-driven previews (~40 ms): long enough to
    /// coalesce key-repeat, short enough to feel live. `.zero` applies inline.
    private let debounce: Duration
    private var previewTask: Task<Void, Never>?
    private var isPreviewing = false

    init(
        defaults: UserDefaults = .standard,
        debounce: Duration = .milliseconds(40),
        apply: @escaping @MainActor (_ light: String, _ dark: String) -> Void = { light, dark in
            GhosttyAppManager.shared.applyTheme(lightTheme: light, darkTheme: dark)
        }
    ) {
        self.defaults = defaults
        self.debounce = debounce
        self.apply = apply
        let pair = GhosttyThemePersistence.load(from: defaults)
        self.lightTheme = pair.lightTheme
        self.darkTheme = pair.darkTheme
    }

    var committedPair: GhosttyThemePersistence.Pair {
        GhosttyThemePersistence.Pair(lightTheme: lightTheme, darkTheme: darkTheme)
    }

    func setLightTheme(_ name: String) {
        commit(GhosttyThemePersistence.Pair(lightTheme: name, darkTheme: darkTheme))
    }

    func setDarkTheme(_ name: String) {
        commit(GhosttyThemePersistence.Pair(lightTheme: lightTheme, darkTheme: name))
    }

    func setPair(lightTheme: String, darkTheme: String) {
        commit(GhosttyThemePersistence.Pair(lightTheme: lightTheme, darkTheme: darkTheme))
    }

    /// Transiently apply a pair without persisting. Debounced, so arrowing
    /// through a long theme list rebuilds the config at most once per window.
    func preview(lightTheme: String, darkTheme: String) {
        isPreviewing = true
        previewTask?.cancel()
        previewTask = nil

        guard debounce > .zero else {
            apply(lightTheme, darkTheme)
            return
        }

        previewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.apply(lightTheme, darkTheme)
        }
    }

    /// Revert any in-flight or applied preview back to the committed pair.
    func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        previewTask?.cancel()
        previewTask = nil
        apply(lightTheme, darkTheme)
    }

    private func commit(_ pair: GhosttyThemePersistence.Pair) {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        lightTheme = pair.lightTheme
        darkTheme = pair.darkTheme
        GhosttyThemePersistence.save(pair, to: defaults)
        apply(pair.lightTheme, pair.darkTheme)
    }
}
