//
//  TerminalThemeOverlay.swift
//  WorkspaceManager
//
//  Cmd+Shift+P command overlay, seeded with the Terminal Theme commands. Built
//  on the same palette pattern as the Cmd+P switcher and structured to grow
//  into a fuller command runner later. Pick the light or dark slot, search,
//  preview live on highlight, commit on Enter, revert on Esc.
//

import AppKit
import SwiftUI

/// Which half of the light/dark Terminal Theme pair is being edited.
enum TerminalThemeSlot: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }
}

struct TerminalThemeOverlay: View {
    @ObservedObject var store: GhosttyThemeStore
    let onDismiss: () -> Void

    @State private var slot: TerminalThemeSlot = .dark
    @State private var allThemes: [GhosttyTheme] = []
    @State private var featuredThemes: [GhosttyTheme] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalThemeListView(
                allThemes: allThemes,
                featuredThemes: featuredThemes,
                currentSelectionName: currentSelectionName,
                showsDefaultRow: true,
                onPreview: preview(_:),
                onCommit: commit(_:),
                onCancel: cancel
            )
            .id(slot)
        }
        .frame(width: 520, height: 460)
        .background(.thinMaterial)
        .onAppear {
            slot = currentAppearanceSlot()
            loadThemes()
        }
        .onChange(of: slot) { _, _ in
            store.endPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.secondary)
                Text("Terminal Theme")
                    .font(.headline)
                Spacer()
                Picker("Slot", selection: $slot) {
                    ForEach(TerminalThemeSlot.allCases) { slot in
                        Text(slot.title).tag(slot)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            Text(slotDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var currentSelectionName: String {
        slot == .light ? store.lightTheme : store.darkTheme
    }

    private var slotDescription: String {
        let current = currentSelectionName.isEmpty ? "Ghostty Default" : currentSelectionName
        var description = "Editing \(slot.title.lowercased()) appearance · current: \(current)"
        if slot != currentAppearanceSlot() {
            description += " · preview shows in \(slot.title.lowercased()) mode"
        }
        return description
    }

    private func preview(_ name: String) {
        switch slot {
        case .light: store.preview(lightTheme: name, darkTheme: store.darkTheme)
        case .dark: store.preview(lightTheme: store.lightTheme, darkTheme: name)
        }
    }

    private func commit(_ name: String) {
        switch slot {
        case .light: store.setLightTheme(name)
        case .dark: store.setDarkTheme(name)
        }
        onDismiss()
    }

    private func cancel() {
        store.endPreview()
        onDismiss()
    }

    private func currentAppearanceSlot() -> TerminalThemeSlot {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    private func loadThemes() {
        let all = GhosttyThemeCatalog.bundledThemes()
        allThemes = all
        featuredThemes = GhosttyThemeCatalog.featured(in: all)
    }
}
