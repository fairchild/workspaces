//
//  ContentViewPreviewHost.swift
//  WorkspaceManager
//
//  Owns the stores ContentView requires so the SwiftUI preview can construct one.
//

import SwiftData
import SwiftUI
import WorkspaceManagerCore

#Preview {
    ContentViewPreviewHost()
        .modelContainer(for: [Repo.self, Workspace.self, WebSource.self], inMemory: true)
}

private struct ContentViewPreviewHost: View {
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @State private var lastSurfaceRawValue = ""
    @StateObject private var appCommandState = AppCommandState()
    @StateObject private var tileTreeStore = TileTreeStore()
    @StateObject private var workspaceProviderSetupCoordinator = WorkspaceProviderSetupCoordinator()
    @StateObject private var smokeDriver = SmokeScenarioDriver(environment: [:])

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            appCommandState: appCommandState,
            tileTreeStore: tileTreeStore,
            workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
            smokeDriver: smokeDriver
        )
    }
}
