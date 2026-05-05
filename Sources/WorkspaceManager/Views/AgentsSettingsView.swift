//
//  AgentsSettingsView.swift
//  WorkspaceManager
//
//  Settings → Agents pane. Owns the opt-in toggle that installs the Claude Code
//  hook routes into ~/.claude/settings.json via ClaudeSettingsInstaller. Reflects
//  actual on-disk install state so the toggle is self-healing if the user reverts
//  the install externally.
//
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 1 ("Configuration").
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

private enum AgentsSettingsStorage {
    static let toggleKey = "agents.claudeHooks.enabled"
    static let bannerDismissedKey = "agents.claudeHooks.bannerDismissed"
}

struct AgentsSettingsView: View {
    let installer: (any ClaudeSettingsInstalling)?

    @AppStorage(AgentsSettingsStorage.toggleKey)
    private var hooksEnabled: Bool = false

    @State private var isInstalled = false
    @State private var isLoading = true
    @State private var showPreviewSheet = false
    @State private var previewBody = ""
    @State private var lastBackupPath: String?
    @State private var settingsModificationDate: Date?
    @State private var settingsURL: URL?
    @State private var pendingError: String?
    @State private var transientFeedback: String?
    @State private var isInstalling = false
    @State private var showRevertSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code Integration")
                .font(.headline)

            Toggle(
                "Send Claude Code status to WorkSpaces",
                isOn: Binding(
                    get: { hooksEnabled },
                    set: { newValue in
                        Task { await handleToggleChange(to: newValue) }
                    }
                )
            )
            .disabled(installer == nil || isInstalling)

            Text(
                "Adds non-destructive HTTP hook routes to ~/.claude/settings.json so the "
                    + "host can show live tool, prompt, and permission state in the sidebar."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            statusRow

            if isInstalled {
                Button("Show preview again") {
                    Task { await loadAndShowPreview() }
                }
                .controlSize(.small)
            }

            if let transientFeedback {
                Label(transientFeedback, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            if installer == nil {
                Text("Installer is unavailable in this build.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $showPreviewSheet) {
            ClaudeHookPreviewSheet(
                preview: previewBody,
                isInstalling: $isInstalling,
                onAccept: { Task { await runInstall() } },
                onCancel: {
                    showPreviewSheet = false
                    hooksEnabled = isInstalled
                }
            )
        }
        .sheet(isPresented: $showRevertSheet) {
            ClaudeHookRevertSheet(
                backupPath: lastBackupPath,
                settingsPath: settingsURL?.path
            ) {
                showRevertSheet = false
            }
        }
        .alert(
            "Could Not Update Claude Settings",
            isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { pendingError = nil }
        } message: {
            Text(pendingError ?? "Unknown error.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbolName)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.callout.weight(.medium))
            }
            if let url = settingsURL {
                Text(url.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let date = settingsModificationDate {
                Text("Last modified \(Self.dateFormatter.string(from: date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isLoading {
                Text("Checking…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet created")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let backup = lastBackupPath {
                Text("Backup: \(backup)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusSymbolName: String {
        if isLoading { return "circle.dotted" }
        return isInstalled ? "checkmark.circle.fill" : "circle"
    }

    private var statusColor: Color {
        if isLoading { return .secondary }
        return isInstalled ? .green : .secondary
    }

    private var statusTitle: String {
        if isLoading { return "Checking install state…" }
        return isInstalled ? "Hooks installed" : "Hooks not installed"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Actions

    private func refresh() async {
        guard let installer else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        let installed = await installer.isInstalled()
        let url = await installer.userSettingsURL()
        let modDate = await installer.userSettingsModificationDate()
        let backup = await installer.mostRecentBackupPath()
        await MainActor.run {
            self.isInstalled = installed
            self.settingsURL = url
            self.settingsModificationDate = modDate
            if let backup { self.lastBackupPath = backup }
            if installed && !hooksEnabled { hooksEnabled = true }
            if !installed && hooksEnabled { hooksEnabled = false }
        }
    }

    private func handleToggleChange(to newValue: Bool) async {
        guard installer != nil else { return }
        if newValue && !isInstalled {
            await loadAndShowPreview()
        } else if !newValue && isInstalled {
            showRevertSheet = true
            // Optimistically reflect the on-disk state until the user reverts.
            hooksEnabled = true
        } else {
            hooksEnabled = newValue
        }
    }

    private func loadAndShowPreview() async {
        guard let installer else { return }
        do {
            let preview = try await installer.renderPreview()
            await MainActor.run {
                self.previewBody = preview
                self.showPreviewSheet = true
            }
        } catch {
            await MainActor.run { self.pendingError = error.localizedDescription }
        }
    }

    private func runInstall() async {
        guard let installer else { return }
        await MainActor.run { self.isInstalling = true }
        defer { Task { @MainActor in self.isInstalling = false } }

        do {
            try await installer.install()
            await refresh()
            await MainActor.run {
                self.showPreviewSheet = false
                self.transientFeedback =
                    "Installed. Backup at \(self.lastBackupPath ?? "—")."
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run { self.transientFeedback = nil }
        } catch {
            await MainActor.run {
                self.pendingError = error.localizedDescription
                self.showPreviewSheet = false
                self.hooksEnabled = self.isInstalled
            }
        }
    }
}

private struct ClaudeHookPreviewSheet: View {
    let preview: String
    @Binding var isInstalling: Bool
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Claude settings change")
                .font(.title3.weight(.semibold))

            Text(
                "WorkSpaces will deep-merge the following hook entries into your "
                    + "existing settings. Untouched keys are preserved, and a "
                    + "timestamped backup is written before any change."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            ScrollView {
                Text(preview.isEmpty ? "(no changes)" : preview)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                if isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isInstalling)
                Button("Accept and install", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct ClaudeHookRevertSheet: View {
    let backupPath: String?
    let settingsPath: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revert manually")
                .font(.title3.weight(.semibold))

            Text(
                "Surgical removal of merged JSON is not yet automated. To disable the "
                    + "integration cleanly, restore the timestamped backup over the live "
                    + "settings file, then flip the toggle off."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let backupPath, let settingsPath {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run in Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("cp \"\(backupPath)\" \"\(settingsPath)\"")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button("Copy command") {
                        let cmd = "cp \"\(backupPath)\" \"\(settingsPath)\""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    }
                    .controlSize(.small)
                }
            } else {
                Text("No backup file is recorded yet — restore from your own backup before disabling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

#Preview {
    AgentsSettingsView(installer: nil)
        .padding()
        .frame(width: 520)
}
