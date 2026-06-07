//
//  TerminalThemeSettingsSection.swift
//  WorkspaceManager
//
//  Settings → Terminal: light + dark theme pickers. Each opens the same
//  searchable theme list used by the Cmd+Shift+P overlay, and edits live via
//  the shared GhosttyThemeStore.
//

import SwiftUI

struct TerminalThemeSettingsSection: View {
    @ObservedObject var store: GhosttyThemeStore

    @State private var allThemes: [GhosttyTheme] = []
    @State private var featuredThemes: [GhosttyTheme] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terminal Theme")
                .font(.headline)

            Text("Pick a light and dark color theme for your terminals. The active theme follows the macOS appearance.")
                .font(.caption)
                .foregroundStyle(.secondary)

            slotRow(.light)
            slotRow(.dark)
        }
        .onAppear(perform: loadThemes)
    }

    private func slotRow(_ slot: TerminalThemeSlot) -> some View {
        TerminalThemeSlotField(
            slot: slot,
            store: store,
            allThemes: allThemes,
            featuredThemes: featuredThemes
        )
    }

    private func loadThemes() {
        let all = GhosttyThemeCatalog.bundledThemes()
        allThemes = all
        featuredThemes = GhosttyThemeCatalog.featured(in: all)
    }
}

private struct TerminalThemeSlotField: View {
    let slot: TerminalThemeSlot
    @ObservedObject var store: GhosttyThemeStore
    let allThemes: [GhosttyTheme]
    let featuredThemes: [GhosttyTheme]

    @State private var isShowingPicker = false

    var body: some View {
        HStack {
            Text("\(slot.title) theme")
                .font(.callout)
            Spacer()
            Button {
                isShowingPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(displayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $isShowingPicker, arrowEdge: .trailing) {
                TerminalThemeListView(
                    allThemes: allThemes,
                    featuredThemes: featuredThemes,
                    currentSelectionName: committedName,
                    showsDefaultRow: true,
                    onPreview: preview(_:),
                    onCommit: { name in
                        commit(name)
                        isShowingPicker = false
                    },
                    onCancel: {
                        store.endPreview()
                        isShowingPicker = false
                    }
                )
                .frame(width: 360, height: 420)
            }
            .onChange(of: isShowingPicker) { _, isShowing in
                if !isShowing { store.endPreview() }
            }
        }
    }

    private var committedName: String {
        slot == .light ? store.lightTheme : store.darkTheme
    }

    private var displayName: String {
        committedName.isEmpty ? "Ghostty Default" : committedName
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
    }
}
