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
            header
            Divider()

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
        .navigationSubtitle(source.allowedHost)
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(source.allowedHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                guard let baseURL = source.baseURL else { return }
                NSWorkspace.shared.open(baseURL)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .help("Open in Browser")

            Button {
                let webView = surfaceStore.ensureSurface(for: source)
                if let currentURL = webView.url {
                    webView.load(URLRequest(url: currentURL))
                } else if let baseURL = source.baseURL {
                    webView.load(URLRequest(url: baseURL))
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
