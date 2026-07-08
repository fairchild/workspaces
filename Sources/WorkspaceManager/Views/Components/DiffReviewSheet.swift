//
//  DiffReviewSheet.swift
//  WorkspaceManager
//
//  Presents the native `DiffReviewView` for one changed file: loads the working-tree diff
//  via `GitService`, provides the scroll container the render view expects, and hosts the
//  native stage / unstage / discard controls beside the review (see #704 Phase 3). Reused from
//  the Changes tab and the just-saved edit path. Discard is confirm-gated and routes tracked
//  files to `git checkout --` and untracked files to a single-path delete, so a "discard" of a
//  new file is never silent.
//

import SwiftUI
import WorkspaceManagerCore

struct DiffReviewSheet: View {
    let filePath: String
    let directoryURL: URL
    /// Known git status for `filePath`, if the caller has it (the Changes tab does). When nil the
    /// sheet resolves it so discard can word itself and route correctly for untracked files.
    var status: GitStatus? = nil
    /// Invoked after a stage / unstage / discard mutates the working tree so callers can refresh.
    var onChanged: () -> Void = {}
    let onClose: () -> Void

    @Environment(\.gitService) private var gitService
    @State private var phase: Phase = .loading
    @State private var resolvedStatus: GitStatus?
    @State private var isBusy = false
    @State private var actionError: String?
    @State private var isConfirmingDiscard = false

    private enum Phase {
        case loading
        case loaded(UnifiedDiff)
        case failed(String)
    }

    private var isUntracked: Bool {
        resolvedStatus == .untracked
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review Diff")
                    .font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let diff):
                ScrollView([.vertical, .horizontal]) {
                    DiffReviewView(diff: diff)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Could not load diff",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if case .loading = phase {
                EmptyView()
            } else {
                DiffReviewActionBar(
                    isUntracked: isUntracked,
                    isBusy: isBusy,
                    errorMessage: actionError,
                    onStage: {
                        Task {
                            await performAction {
                                try await gitService.stage(file: filePath, at: directoryURL)
                            }
                        }
                    },
                    onUnstage: {
                        Task {
                            await performAction {
                                try await gitService.unstage(file: filePath, at: directoryURL)
                            }
                        }
                    },
                    onDiscardRequested: { isConfirmingDiscard = true }
                )
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task(id: filePath) { await load() }
        .confirmationDialog(
            discardConfirmationTitle,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(isUntracked ? "Delete File" : "Discard Changes", role: .destructive) {
                Task { await performDiscard() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(discardConfirmationMessage)
        }
    }

    private var discardConfirmationTitle: String {
        isUntracked ? "Delete “\(filePath)”?" : "Discard changes to “\(filePath)”?"
    }

    private var discardConfirmationMessage: String {
        isUntracked
            ? "This permanently deletes the untracked file. It is not tracked by git and cannot be recovered."
            : "This restores the file to its last staged or committed contents. Unsaved working-tree changes are lost and cannot be recovered."
    }

    private func load() async {
        phase = .loading
        actionError = nil
        // Optimistic initial value avoids a flash, but always re-resolve from git so a reload after
        // Stage/Unstage routes discard correctly instead of trusting the now-stale passed-in status.
        resolvedStatus = status
        do {
            async let diffTask = gitService.diff(file: filePath, at: directoryURL)
            resolvedStatus =
                try? await gitService.getStatus(at: directoryURL)
                .first(where: { $0.path == filePath })?.status
            phase = .loaded(try await diffTask)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func performDiscard() async {
        await performAction {
            if isUntracked {
                try await gitService.discardUntracked(file: filePath, at: directoryURL)
            } else {
                try await gitService.discard(file: filePath, at: directoryURL)
            }
        }
    }

    private func performAction(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        actionError = nil
        do {
            try await operation()
            onChanged()
            await load()
        } catch {
            actionError = error.localizedDescription
        }
        isBusy = false
    }
}

/// Presentational stage / unstage / discard controls for the diff review surface. Pulled out of
/// `DiffReviewSheet` so the exact control set — including the untracked "Delete" wording and the
/// inline action-error banner — renders deterministically under `ImageRenderer` for PR evidence.
struct DiffReviewActionBar: View {
    let isUntracked: Bool
    let isBusy: Bool
    let errorMessage: String?
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscardRequested: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()

                Button("Stage", action: onStage)
                    .disabled(isBusy)
                    .help("Stage this file (git add)")

                Button("Unstage", action: onUnstage)
                    .disabled(isBusy)
                    .help("Unstage this file (git reset HEAD)")

                Button(isUntracked ? "Delete" : "Discard", role: .destructive, action: onDiscardRequested)
                    .disabled(isBusy)
                    .help(
                        isUntracked
                            ? "Delete this untracked file (permanent)"
                            : "Discard working-tree changes to this file"
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
