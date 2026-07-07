//
//  DiffReviewSheet.swift
//  WorkspaceManager
//
//  Presents the native `DiffReviewView` for one changed file: loads the working-tree diff
//  via `GitService`, provides the scroll container the render view expects, and shows quiet
//  loading / empty / error states. Reused from the Changes tab and the just-saved edit path
//  (see #704 Phase 3). Staging/discard controls are a later slice.
//

import SwiftUI
import WorkspaceManagerCore

struct DiffReviewSheet: View {
    let filePath: String
    let directoryURL: URL
    let onClose: () -> Void

    @Environment(\.gitService) private var gitService
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(UnifiedDiff)
        case failed(String)
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
        }
        .frame(minWidth: 480, minHeight: 360)
        .task(id: filePath) { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let diff = try await gitService.diff(file: filePath, at: directoryURL)
            phase = .loaded(diff)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
