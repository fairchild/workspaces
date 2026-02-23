//
//  WorkspaceManagerApp.swift
//  WorkspaceManager
//
//  Main entry point - SwiftUI lifecycle with AppKit hooks for window management
//

import AppKit
import Foundation
import SwiftData
import SwiftUI
import WorkspaceManagerCore

@main
struct WorkspaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.newWorkspaceAction) private var newWorkspaceAction
    @FocusedValue(\.toggleSidebarAction) private var toggleSidebarAction
    @FocusedValue(\.toggleInspectorAction) private var toggleInspectorAction

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Repo.self, Workspace.self])
        let launchEnvironment = ProcessInfo.processInfo.environment
        let shouldUseInMemoryStore = launchEnvironment["WORKSPACES_UI_FIXTURE"] == "1"
        let modelConfiguration = resolvedModelConfiguration(
            schema: schema,
            launchEnvironment: launchEnvironment
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])

            if shouldUseInMemoryStore {
                seedUIFixtureDataIfNeeded(in: container.mainContext)
            }

            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainWindowRootView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1400, height: 900)
        .windowResizability(.contentSize)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Workspace...") {
                    newWorkspaceAction?()
                }
                .keyboardShortcut(
                    AppChromeShortcut.newWorkspace.keyEquivalent,
                    modifiers: AppChromeShortcut.newWorkspace.eventModifiers
                )

                Button("Toggle Sidebar") {
                    toggleSidebarAction?()
                }
                .keyboardShortcut(
                    AppChromeShortcut.toggleSidebar.keyEquivalent,
                    modifiers: AppChromeShortcut.toggleSidebar.eventModifiers
                )

                Button("Toggle Inspector") {
                    toggleInspectorAction?()
                }
                .keyboardShortcut(
                    AppChromeShortcut.toggleInspector.keyEquivalent,
                    modifiers: AppChromeShortcut.toggleInspector.eventModifiers
                )
            }

            SidebarCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

private func resolvedModelConfiguration(
    schema: Schema,
    launchEnvironment: [String: String]
) -> ModelConfiguration {
    let shouldUseInMemoryStore = launchEnvironment["WORKSPACES_UI_FIXTURE"] == "1"
    if shouldUseInMemoryStore {
        return ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
    }

    if let requestedDataDirectory = launchEnvironment["WORKSPACES_DATA_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !requestedDataDirectory.isEmpty
    {
        let expandedPath = (requestedDataDirectory as NSString).expandingTildeInPath
        let requestedURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        do {
            return try persistentModelConfiguration(schema: schema, storeDirectory: requestedURL)
        } catch {
            NSLog(
                "[ModelStore] Failed to use WORKSPACES_DATA_DIR '%@': %@",
                requestedURL.path,
                String(describing: error)
            )
        }
    }

    do {
        let appSupportDirectory = try defaultModelStoreDirectory()
        return try persistentModelConfiguration(schema: schema, storeDirectory: appSupportDirectory)
    } catch {
        let fallbackDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".workspacemanager-data", isDirectory: true)
        NSLog(
            "[ModelStore] Falling back to workspace-local store (%@): %@",
            fallbackDirectory.path,
            String(describing: error)
        )

        do {
            return try persistentModelConfiguration(schema: schema, storeDirectory: fallbackDirectory)
        } catch {
            NSLog(
                "[ModelStore] Falling back to in-memory store: %@",
                String(describing: error)
            )
            return ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        }
    }
}

private func defaultModelStoreDirectory() throws -> URL {
    let appSupportDirectory = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let modelDirectory = appSupportDirectory.appendingPathComponent("WorkspaceManager", isDirectory: true)
    try ensureWritableDirectory(at: modelDirectory)
    return modelDirectory
}

private func persistentModelConfiguration(
    schema: Schema,
    storeDirectory: URL
) throws -> ModelConfiguration {
    try ensureWritableDirectory(at: storeDirectory)
    let storeURL = storeDirectory.appendingPathComponent("default.store", isDirectory: false)
    return ModelConfiguration(
        schema: schema,
        url: storeURL
    )
}

private func ensureWritableDirectory(at directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )

    let probeURL = directory.appendingPathComponent(
        ".write-probe-\(UUID().uuidString)",
        isDirectory: false
    )
    try Data("ok".utf8).write(to: probeURL, options: .atomic)
    try FileManager.default.removeItem(at: probeURL)
}

private func seedUIFixtureDataIfNeeded(in context: ModelContext) {
    do {
        let repoCount = try context.fetchCount(FetchDescriptor<Repo>())
        guard repoCount == 0 else { return }
    } catch {
        // If readback fails, continue and try to seed once.
    }

    let codeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code", isDirectory: true)

    let skillsRepo = Repo(
        name: "skills",
        localPath: codeRoot.appendingPathComponent("skills", isDirectory: true)
    )
    let servicesRepo = Repo(
        name: "services",
        localPath: codeRoot.appendingPathComponent("services", isDirectory: true)
    )
    let superpowersRepo = Repo(
        name: "superpowers",
        localPath: codeRoot.appendingPathComponent("superpowers", isDirectory: true)
    )
    let workspacesRepo = Repo(
        name: "workspaces",
        localPath: codeRoot.appendingPathComponent("workspaces", isDirectory: true)
    )

    context.insert(skillsRepo)
    context.insert(servicesRepo)
    context.insert(superpowersRepo)
    context.insert(workspacesRepo)

    let skillsWorkspace = Workspace(
        name: "skills-v13",
        path: codeRoot.appendingPathComponent("workspaces/skills/skills-v13", isDirectory: true),
        sourceRepo: skillsRepo,
        gitBranch: "workspace/skills-v13"
    )
    context.insert(skillsWorkspace)

    do {
        try context.save()
    } catch {
        NSLog("[UIFixture] Failed to seed fixture data: %@", String(describing: error))
    }
}

private struct MainWindowRootView: View {
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @StateObject private var hostTerminalState = HostTerminalStateStore()

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            hostTerminalState: hostTerminalState
        )
        .onOpenURL { url in
            if deepLinkState.enqueue(url: url) {
                NSLog("[DeepLink] Received request: %@", url.absoluteString)
            } else {
                NSLog("[DeepLink] Ignored unsupported URL: %@", url.absoluteString)
            }
        }
    }
}

// MARK: - AppDelegate for AppKit-level hooks

class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowObserver: Any?
    private static let noActivateOnLaunchEnvKey = "WORKSPACES_NO_ACTIVATE_ON_LAUNCH"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidFinishLaunching")
        PerformanceSignposts.beginLaunchToFirstPromptIfNeeded()

        GhosttyAppManager.shared.initializeIfNeeded()

        // Keep regular app activation policy so it appears in the dock/menu bar.
        // Foreground activation is optional for shared-desktop workflows.
        NSApp.setActivationPolicy(.regular)
        if shouldActivateOnLaunch() {
            NSApp.activate(ignoringOtherApps: true)
            NSLog("[AppDelegate] Set activation policy to .regular and activated")
        } else {
            NSLog(
                "[AppDelegate] Set activation policy to .regular (launch activation disabled via %@)",
                Self.noActivateOnLaunchEnvKey
            )
        }
        // Applying after activation-policy setup avoids Dock showing the generic executable icon.
        applyApplicationIconIfAvailable()

        // Register existing windows with focus manager
        for window in NSApp.windows {
            TerminalFocusManager.shared.registerWindow(window)
        }

        // Observe new window creation to register with focus manager
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                TerminalFocusManager.shared.registerWindow(window)
            }
        }
    }

    private func shouldActivateOnLaunch() -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[Self.noActivateOnLaunchEnvKey] else {
            return true
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return false
        default:
            return true
        }
    }

    private func applyApplicationIconIfAvailable() {
        if let bundledIcon = NSImage(named: NSImage.Name("AppIcon")) {
            NSApp.applicationIconImage = bundledIcon
            NSApp.dockTile.display()
            return
        }

        // SwiftPM debug launches run the raw binary directly; load icon PNG from module resources.
        let fallbackIconNames = [
            "icon_512x512@2x",
            "icon_512x512",
            "icon_256x256@2x",
            "icon_256x256",
        ]
        let appIconSubdirectory = "Assets.xcassets/AppIcon.appiconset"

        for iconName in fallbackIconNames {
            guard
                let iconURL = Bundle.module.url(
                    forResource: iconName,
                    withExtension: "png",
                    subdirectory: appIconSubdirectory
                )
            else {
                continue
            }

            guard let fallbackIcon = NSImage(contentsOf: iconURL) else {
                continue
            }

            NSApp.applicationIconImage = fallbackIcon
            NSApp.dockTile.display()
            return
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true  // Change to false for background operation
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidBecomeActive")
        applyApplicationIconIfAvailable()
        GhosttyAppManager.shared.setFocus(true)
        // When app becomes active, ensure focused terminal gets focus restored
        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            TerminalFocusManager.shared.requestFocus(for: terminal)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidResignActive")
        GhosttyAppManager.shared.setFocus(false)
    }
}

// MARK: - Environment Keys

private struct GitServiceKey: EnvironmentKey {
    static let defaultValue: any GitServiceProtocol = GitService.shared
}

private struct WorkspaceServiceKey: EnvironmentKey {
    static let defaultValue: any WorkspaceServiceProtocol = WorkspaceService.shared
}

extension EnvironmentValues {
    var gitService: any GitServiceProtocol {
        get { self[GitServiceKey.self] }
        set { self[GitServiceKey.self] = newValue }
    }

    var workspaceService: any WorkspaceServiceProtocol {
        get { self[WorkspaceServiceKey.self] }
        set { self[WorkspaceServiceKey.self] = newValue }
    }
}

// MARK: - Focused Scene Values

private struct NewWorkspaceActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

private struct ToggleSidebarActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

private struct ToggleInspectorActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var newWorkspaceAction: (@MainActor () -> Void)? {
        get { self[NewWorkspaceActionKey.self] }
        set { self[NewWorkspaceActionKey.self] = newValue }
    }

    var toggleSidebarAction: (@MainActor () -> Void)? {
        get { self[ToggleSidebarActionKey.self] }
        set { self[ToggleSidebarActionKey.self] = newValue }
    }

    var toggleInspectorAction: (@MainActor () -> Void)? {
        get { self[ToggleInspectorActionKey.self] }
        set { self[ToggleInspectorActionKey.self] = newValue }
    }
}
