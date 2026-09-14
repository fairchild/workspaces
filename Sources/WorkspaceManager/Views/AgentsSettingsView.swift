//
//  AgentsSettingsView.swift
//  WorkspaceManager
//
//  Settings → Agents pane. Owns the opt-in toggle that installs the Claude Code
//  hook routes into ~/.claude/settings.json via ClaudeSettingsInstaller. Reflects
//  actual on-disk install state so the toggle is self-healing if the user reverts
//  the install externally.
//
//  Installs the command hook and status-line forwarders. The status row says whether
//  the integration is active, degraded or failed, from the settings-file probe, the
//  hook listener probe, and the last install attempt.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

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

    /// Owns the hook socket the listener probe connects to and the record of the last
    /// install attempt that failed, the launch repair included, so a failure outlives
    /// this pane being closed and reopened.
    @ObservedObject private var lifecycle = ClaudeIntegrationLifecycle.shared

    @State private var isInstalled = false
    @State private var isLoading = true
    @State private var refreshGeneration = 0
    @State private var listenerFailure: String?
    @State private var showPreviewSheet = false
    @State private var previewBody = ""
    @State private var lastBackupPath: String?
    @State private var settingsModificationDate: Date?
    @State private var settingsURL: URL?
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

            AgentsIntegrationStatusRow(
                status: status,
                settingsPath: settingsURL?.path,
                settingsModificationDate: settingsModificationDate,
                backupPath: lastBackupPath,
                onInstall: { Task { await loadAndShowPreview() } },
                onRecheck: { Task { await refresh() } }
            )

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
        // Keyed on the installer arriving: Settings can open before the lifecycle publishes it.
        .task(id: installer != nil) { await refresh() }
        // Re-read whenever the lifecycle publishes (an installer arriving, a failure recorded or
        // cleared), so listener health is never only the answer from when the pane appeared.
        .onReceive(lifecycle.objectWillChange) { _ in
            Task { await refresh() }
        }
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
                    lifecycle.clearInstallFailure()
                    showRevertSheet = false
                    Task { await refresh() }
                }
            )
        }
    }

    private var status: AgentsIntegrationStatus {
        AgentsIntegrationStatus(
            isChecking: isLoading,
            isOptedIn: hooksEnabled,
            isInstalled: isInstalled,
            listenerFailure: listenerFailure,
            installFailure: lifecycle.lastInstallFailure
        )
    }

    // MARK: - Actions

    private func refresh() async {
        guard let installer else {
            isLoading = false
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let failureCountAtStart = lifecycle.installFailureCount
        isLoading = true
        // The launch repair is an install attempt: waiting for it keeps the row from
        // reading the settings file and the failure record before that attempt lands.
        await lifecycle.startupTask?.value
        let installed = await installer.isInstalled()
        let url = await installer.userSettingsURL()
        let modDate = await installer.userSettingsModificationDate()
        let backup = await installer.mostRecentBackupPath()
        let socketPath = lifecycle.socketPath
        let listenerFailure = await ClaudeIntegrationLifecycle.hookListenerProbeFailure(
            socketPath: socketPath,
            timeout: ClaudeIntegrationLifecycle.hookListenerProbeTimeout
        )
        await MainActor.run {
            // A refresh that started later read everything later; its answer is the current one.
            guard generation == refreshGeneration else { return }
            self.isInstalled = installed
            self.listenerFailure = listenerFailure
            self.settingsURL = url
            self.settingsModificationDate = modDate
            if let backup { self.lastBackupPath = backup }
            // Hooks found installed settle a failure this refresh could have seen, never one
            // recorded while it was still reading.
            if installed { lifecycle.clearInstallFailure(ifRecordedBefore: failureCountAtStart) }
            self.isLoading = false
            // Important: do NOT auto-flip the opt-in toggle to match the on-disk
            // state. If the user opted in but later edited settings.json by hand
            // (e.g. removed the http hooks), the status row turns degraded and offers
            // a re-install rather than silently resetting their preference.
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
            // Turning the integration off withdraws the install a failure was reporting on.
            if !newValue { lifecycle.clearInstallFailure() }
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
            await MainActor.run { lifecycle.recordInstallFailure(error.localizedDescription) }
        }
    }

    private func runInstall() async {
        guard let installer else { return }
        await MainActor.run { self.isInstalling = true }
        defer { Task { @MainActor in self.isInstalling = false } }

        do {
            try await installer.install()
            await MainActor.run { lifecycle.clearInstallFailure() }
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
                // The status row turns failed and carries the error text. The persisted
                // opt-in stays as it was: a user who wasn't opted in still isn't.
                lifecycle.recordInstallFailure(error.localizedDescription)
                self.showPreviewSheet = false
            }
        }
    }
}

/// What the Agents status row says about the Claude Code integration. Active, degraded and
/// failed are its health; checking and not installed are the states around them.
enum AgentsIntegrationStatus: Equatable {
    case checking
    case notInstalled
    case active
    case degraded(Degradation)
    case failed(error: String)

    enum Degradation: Equatable {
        /// Opted in, but the Claude settings no longer carry the WorkSpaces hooks.
        case hooksMissing
        /// The hooks are installed, but this app's listener didn't answer on the hook socket:
        /// nothing did, or another process holds it.
        case notListening(reason: String)
    }

    /// An install attempt that errored outranks the settings file: the user acted, and the
    /// row answers that act until the lifecycle clears the record. The listener only matters
    /// once the hooks are installed to call it.
    init(
        isChecking: Bool,
        isOptedIn: Bool,
        isInstalled: Bool,
        listenerFailure: String?,
        installFailure: String?
    ) {
        if isChecking {
            self = .checking
        } else if let installFailure {
            self = .failed(error: installFailure)
        } else if isInstalled {
            self = listenerFailure.map { .degraded(.notListening(reason: $0)) } ?? .active
        } else {
            self = isOptedIn ? .degraded(.hooksMissing) : .notInstalled
        }
    }

    var symbolName: String {
        switch self {
        case .checking: return "circle.dotted"
        case .notInstalled: return "circle"
        case .active: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking, .notInstalled: return .secondary
        case .active: return .green
        case .degraded: return .orange
        case .failed: return .red
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking install state…"
        case .notInstalled: return "Hooks not installed"
        case .active: return "Active: hooks installed and this app's listener answered"
        case .degraded(.hooksMissing): return "Degraded: Claude settings no longer carry the WorkSpaces hooks"
        case .degraded(.notListening): return "Degraded: hooks installed, but this app isn't listening for them"
        case .failed: return "Failed: the hooks couldn't be installed"
        }
    }

    enum Action: Hashable {
        case reinstall
        case tryAgain
        case checkAgain

        var title: String {
            switch self {
            case .reinstall: return "Re-install"
            case .tryAgain: return "Try again"
            case .checkAgain: return "Check again"
            }
        }
    }

    /// The row's buttons, in order. Every state but failed can re-read the integration, since a
    /// listener can stop answering after any probe; failed offers the install again instead.
    var actions: [Action] {
        switch self {
        case .failed: return [.tryAgain]
        case .degraded(.hooksMissing): return [.reinstall, .checkAgain]
        case .checking, .notInstalled, .active, .degraded(.notListening): return [.checkAgain]
        }
    }
}

/// The status row in Settings → Agents: a symbol, colour and title per status, the settings
/// file the status describes, and the buttons that status offers. A
/// failure's error text sits behind a disclosure, one click away.
struct AgentsIntegrationStatusRow: View {
    let status: AgentsIntegrationStatus
    let settingsPath: String?
    let settingsModificationDate: Date?
    let backupPath: String?
    let onInstall: () -> Void
    let onRecheck: () -> Void
    @State private var showsFailureDetails: Bool

    init(
        status: AgentsIntegrationStatus,
        settingsPath: String?,
        settingsModificationDate: Date?,
        backupPath: String?,
        showsFailureDetails: Bool = false,
        onInstall: @escaping () -> Void,
        onRecheck: @escaping () -> Void
    ) {
        self.status = status
        self.settingsPath = settingsPath
        self.settingsModificationDate = settingsModificationDate
        self.backupPath = backupPath
        self.onInstall = onInstall
        self.onRecheck = onRecheck
        _showsFailureDetails = State(initialValue: showsFailureDetails)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.color)
                Text(status.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                actions
            }
            detail
            if let settingsPath {
                Text(settingsPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let settingsModificationDate {
                Text("Last modified \(Self.dateFormatter.string(from: settingsModificationDate))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if status == .checking {
                Text("Checking…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet created")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let backupPath {
                Text("Backup: \(backupPath)")
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

    private var actions: some View {
        HStack(spacing: 6) {
            ForEach(status.actions, id: \.self) { action in
                Button(action.title) {
                    switch action {
                    case .reinstall, .tryAgain: onInstall()
                    case .checkAgain: onRecheck()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch status {
        case .degraded(.notListening(let reason)):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let error):
            DisclosureGroup("Details", isExpanded: $showsFailureDetails) {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        case .checking, .notInstalled, .active, .degraded(.hooksMissing):
            EmptyView()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
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

/// Compact status row that surfaces the live status fields populated by the
/// status-line forwarder. Reads `AgentSessionRegistry.statuses` directly — no
/// new `@Published` publisher; we observe via the registry's own `objectWillChange`.
///
/// "Focused session" is the most-recently-updated session in the registry. PR #2
/// avoids reaching into `HostTerminalSession` so the indicator works during dev
/// before any sidebar selection is available; richer focus-aware variants land
/// when sidebar binding stabilizes (PR #3+).
private struct AgentStatusFieldsIndicator: View {
    @ObservedObject var registry: AgentSessionRegistry
    /// `registry.statuses` reads are unobserved and `objectWillChange` fires
    /// only on register/deregister, so per-event refresh rides the registry's
    /// coalesced change signal instead.
    @State private var statusesVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Status")
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
        .onReceive(registry.statusesDidChange) { _ in
            statusesVersion &+= 1
        }
    }

    private var focusedStatus: AgentSessionStatus? {
        _ = statusesVersion
        return registry.statuses.values
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
