//
//  WorkspaceConnectingOverlay.swift
//  WorkspaceManager
//
//  Scrim shown over the detail column while a provider-backed workspace is connecting.
//

import SwiftUI

struct WorkspaceConnectingOverlay: View {
    let workspaceName: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to \(workspaceName ?? "workspace")...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
