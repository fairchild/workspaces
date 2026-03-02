//
//  WebSourceDetailView.swift
//  WorkspaceManager
//
//  Detail pane for URL source browsing.
//

import AppKit
import SwiftUI
import WorkspaceManagerCore

struct WebSourceDetailView: View {
    let source: WebSource
    @ObservedObject var surfaceStore: WebSurfaceStore

    @State private var lastBlockedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if source.baseURL != nil {
                WebSourceView(
                    source: source,
                    surfaceStore: surfaceStore,
                    onBlockedNavigation: { blockedURL in
                        lastBlockedURL = blockedURL
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Invalid URL Source",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This source has an invalid URL. Remove and add it again.")
                )
            }

            if let lastBlockedURL {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Opened outside allowed domain: \(lastBlockedURL.host ?? lastBlockedURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .navigationTitle(source.name)
        .onAppear {
            surfaceStore.cancelPendingRelease()
        }
        .onChange(of: source.id) { _, _ in
            lastBlockedURL = nil
        }
        .onDisappear {
            surfaceStore.scheduleInactiveRelease()
        }
    }
}
