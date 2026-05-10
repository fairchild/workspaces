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
    static let bannerDismissedKey = "agents.claudeHooks.bannerDismissed"
}

struct AgentsSettingsView: View {
    let installer: (any ClaudeSettingsInstalling)?

    /// Shared with `ClaudeIntegrationLifecycle` so silent reinstall on launch sees
    /// the same opt-in state the user toggled here. `true` once the user accepted
    /// the merge preview at least once; flipped `false` on the manual-revert sheet
    /// confirm so subsequent launches stop reinstalling.
    @AppStorage(ClaudeIntegrationDefaults.optedInKey)
    private var hooksEnabled: Bool = false

    /// The registry is owned by the app; in `#Preview` it's absent and the status
    /// section renders an empty placeholder. Use `Environment` (not
    /// `EnvironmentObject`) so the preview path doesn't crash.
    @Environment(\.agentSessionRegistry) private var agentSessionRegistry: AgentSessionRegistry?

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

            if let registry = agentSessionRegistry {
                AgentStatusFieldsIndicator(registry: registry)
            }

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
                settingsPath: settingsURL?.path,
                onClose: { showRevertSheet = false },
                onConfirmReverted: {
                    // User asserts they have restored the backup. Stop reinstalling
                    // on launch and reflect the deopt-in in the toggle. The status
                    // row will refresh on the next .task run.
                    hooksEnabled = false
                    showRevertSheet = false
                    Task { await refresh() }
                }
            )
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

            // Mismatch affordance: user opted in via the toggle, but the on-disk
            // settings file no longer contains our hooks (likely external edit).
            // Don't auto-uninstall — offer a re-install instead.
            if hooksEnabled, !isInstalled, !isLoading {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Your Claude config no longer contains our hooks.")
                        .font(.caption)
                    Spacer()
                    Button("Re-install") {
                        Task { await loadAndShowPreview() }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
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
            // Important: do NOT auto-flip the opt-in toggle to match the on-disk
            // state. If the user opted in but later edited settings.json by hand
            // (e.g. removed the http hooks), surface a re-install affordance via
            // the status row rather than silently resetting their preference.
        }
    }

    private func handleToggleChange(to newValue: Bool) async {
        guard installer != nil else { return }
        if newValue && !isInstalled {
            // Don't flip the persisted opt-in until the user accepts the merge.
            await loadAndShowPreview()
        } else if !newValue && isInstalled {
            // Show the revert sheet but keep the persisted opt-in `true` until the
            // user confirms they have restored the backup. The sheet's
            // `onConfirmReverted` callback flips `hooksEnabled` to false; closing
            // without confirming leaves the opt-in intact.
            hooksEnabled = true
            showRevertSheet = true
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
                // Persist the opt-in so launch-time settings repair stays active.
                self.hooksEnabled = true
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
                // Install failed — leave the persisted opt-in unchanged. If the
                // user wasn't opted-in before, they still aren't.
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
    let onConfirmReverted: () -> Void

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
                Button("I've reverted manually", action: onConfirmReverted)
                    .help("Stop reinstalling on launch. Run the cp command first.")
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Compact status row that surfaces the live status fields populated by Channel 2
/// (status-line forwarder). Reads `AgentSessionRegistry.statuses` directly — no
/// new `@Published` publisher; we observe via the registry's own `objectWillChange`.
///
/// "Focused session" is the most-recently-updated session in the registry. PR #2
/// avoids reaching into `HostTerminalSession` so the indicator works during dev
/// before any sidebar selection is available; richer focus-aware variants land
/// when sidebar binding stabilizes (PR #3+).
private struct AgentStatusFieldsIndicator: View {
    @ObservedObject var registry: AgentSessionRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Status (Channel 2)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let status = focusedStatus {
                statusGrid(status)
            } else {
                Text("No active session yet — start `claude` in an embedded terminal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var focusedStatus: AgentSessionStatus? {
        registry.statuses.values
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .first
    }

    @ViewBuilder
    private func statusGrid(_ status: AgentSessionStatus) -> some View {
        HStack(alignment: .top, spacing: 16) {
            field(title: "Model", value: status.modelDisplayName ?? "—")
            field(title: "Context", value: percentString(status.contextUsedPercent))
            field(title: "Cost", value: costString(status.costUSD))
            field(title: "5h limit", value: percentString(status.fiveHourLimitUsedPercent))
            if let resetsAt = status.fiveHourLimitResetsAt {
                field(title: "Resets", value: Self.timeFormatter.string(from: resetsAt))
            }
        }
        Text(status.cwd)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func field(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func percentString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    private func costString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.3f", value)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

#Preview {
    AgentsSettingsView(installer: nil)
        .padding()
        .frame(width: 520)
}
