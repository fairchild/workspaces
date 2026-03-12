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
    @FocusedValue(\.toggleTerminalPanelAction) private var toggleTerminalPanelAction
    @FocusedValue(\.openInEditorAction) private var openInEditorAction
    private let appRuntimeDependencies = AppRuntimeDependencies.resolved()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
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
            MainWindowRootView(appRuntimeDependencies: appRuntimeDependencies)
                .environment(\.lumeRuntimeService, appRuntimeDependencies.lumeRuntimeService)
                .environment(\.workspaceProviderRegistry, appRuntimeDependencies.workspaceProviderRegistry)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1400, height: 900)
        .windowResizability(.contentSize)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Workspace...") {
                    newWorkspaceAction?()
                }
                .keyboardShortcut(
                    AppChromeShortcut.newWorkspace.keyEquivalent,
                    modifiers: AppChromeShortcut.newWorkspace.eventModifiers
                )

                Button("Open in...") {
                    openInEditorAction?()
                }
                .keyboardShortcut(
                    AppChromeShortcut.openInEditor.keyEquivalent,
                    modifiers: AppChromeShortcut.openInEditor.eventModifiers
                )
                .disabled(openInEditorAction == nil)

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

                Button("Toggle Terminal Panel") {
                    toggleTerminalPanelAction?()
                }
                .keyboardShortcut(
                    AppChromeShortcut.toggleTerminalPanel.keyEquivalent,
                    modifiers: AppChromeShortcut.toggleTerminalPanel.eventModifiers
                )
            }

            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environment(\.lumeRuntimeService, appRuntimeDependencies.lumeRuntimeService)
                .environment(\.workspaceProviderRegistry, appRuntimeDependencies.workspaceProviderRegistry)
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
    let swiftDocs = WebSource(
        name: "Swift Docs",
        baseURLString: "https://docs.swift.org/",
        allowedHost: "docs.swift.org"
    )

    context.insert(skillsRepo)
    context.insert(servicesRepo)
    context.insert(superpowersRepo)
    context.insert(workspacesRepo)
    context.insert(swiftDocs)

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
    private let appRuntimeDependencies: AppRuntimeDependencies
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @SceneStorage(MainWindowLastSurface.storageKey) private var lastSurfaceRawValue = ""
    @StateObject private var hostTerminalState = HostTerminalStateStore()
    @StateObject private var lumeSetupCoordinator: LumeSetupCoordinator
    @StateObject private var hostLumeSmokeAutomation: HostLumeSmokeAutomationController

    init(appRuntimeDependencies: AppRuntimeDependencies) {
        self.appRuntimeDependencies = appRuntimeDependencies
        _lumeSetupCoordinator = StateObject(
            wrappedValue: LumeSetupCoordinator(runtimeService: appRuntimeDependencies.lumeRuntimeService)
        )
        _hostLumeSmokeAutomation = StateObject(
            wrappedValue: HostLumeSmokeAutomationController()
        )
    }

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            hostTerminalState: hostTerminalState,
            lumeSetupCoordinator: lumeSetupCoordinator,
            hostLumeSmokeAutomation: hostLumeSmokeAutomation
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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowObserver: Any?
    private static let noActivateOnLaunchEnvKey = "WORKSPACES_NO_ACTIVATE_ON_LAUNCH"
    private static let appVariantEnvKey = "WORKSPACES_APP_VARIANT"

    private enum AppVariant {
        case standard
        case development

        var dockBadgeLabel: String? {
            switch self {
            case .standard:
                return nil
            case .development:
                return "DEV"
            }
        }

        var windowSubtitle: String? {
            switch self {
            case .standard:
                return nil
            case .development:
                return "Development Build"
            }
        }
    }

    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidFinishLaunching")
        PerformanceSignposts.beginLaunchToFirstPromptIfNeeded()

        GhosttyAppManager.shared.initializeIfNeeded()

        if isCI {
            // CI: fully invisible — no dock icon, no app-switcher, no focus steal.
            NSApp.setActivationPolicy(.accessory)
            NSLog("[AppDelegate] CI detected: .accessory policy (background)")
        } else if !shouldActivateOnLaunch() {
            // Shared-desktop: stay in dock/Cmd+Tab but don't steal focus.
            NSApp.setActivationPolicy(.regular)
            NSLog("[AppDelegate] No-activate mode: .regular policy, skipping activation")
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSLog("[AppDelegate] Set activation policy to .regular and activated")
        }
        // Applying after activation-policy setup avoids Dock showing the generic executable icon.
        applyApplicationIconIfAvailable()
        applyVariantPresentationIfNeeded()

        // Register existing windows with focus manager
        for window in NSApp.windows {
            TerminalFocusManager.shared.registerWindow(window)
            applyVariantPresentation(to: window)
        }

        // Observe new window creation to register with focus manager
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            let window = notification.object as? NSWindow
            Task { @MainActor in
                if let window {
                    TerminalFocusManager.shared.registerWindow(window)
                    self.applyVariantPresentation(to: window)
                }
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

    private func applyVariantPresentationIfNeeded() {
        let variant = appVariant
        NSApp.dockTile.badgeLabel = variant.dockBadgeLabel
        NSApp.dockTile.display()
    }

    private func applyVariantPresentation(to window: NSWindow) {
        let variant = appVariant
        window.subtitle = variant.windowSubtitle ?? ""
    }

    private var appVariant: AppVariant {
        if let rawValue = ProcessInfo.processInfo.environment[Self.appVariantEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty
        {
            return rawValue == "dev" ? .development : .standard
        }

        let executablePath = Bundle.main.executablePath ?? ""
        return executablePath.contains("/.build/") ? .development : .standard
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app alive after the last window closes. This avoids
        // unexpected app termination when a user closes a terminal/window.
        return false
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

private struct WorkspaceProcessMonitorKey: EnvironmentKey {
    static let defaultValue: any WorkspaceProcessMonitorProtocol = WorkspaceProcessMonitor()
}

private struct LumeRuntimeServiceKey: EnvironmentKey {
    static let defaultValue: any LumeRuntimeServiceProtocol = LumeRuntimeService.shared
}

private struct ExternalEditorServiceKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: any ExternalEditorServiceProtocol = ExternalEditorService.shared
}

private struct WorkspaceProviderRegistryKey: EnvironmentKey {
    static let defaultValue = WorkspaceProviderRegistry.live
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

    var workspaceProcessMonitor: any WorkspaceProcessMonitorProtocol {
        get { self[WorkspaceProcessMonitorKey.self] }
        set { self[WorkspaceProcessMonitorKey.self] = newValue }
    }

    var lumeRuntimeService: any LumeRuntimeServiceProtocol {
        get { self[LumeRuntimeServiceKey.self] }
        set { self[LumeRuntimeServiceKey.self] = newValue }
    }

    var externalEditorService: any ExternalEditorServiceProtocol {
        get { self[ExternalEditorServiceKey.self] }
        set { self[ExternalEditorServiceKey.self] = newValue }
    }

    var workspaceProviderRegistry: WorkspaceProviderRegistry {
        get { self[WorkspaceProviderRegistryKey.self] }
        set { self[WorkspaceProviderRegistryKey.self] = newValue }
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

private struct ToggleTerminalPanelActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

private struct OpenInEditorActionKey: FocusedValueKey {
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

    var toggleTerminalPanelAction: (@MainActor () -> Void)? {
        get { self[ToggleTerminalPanelActionKey.self] }
        set { self[ToggleTerminalPanelActionKey.self] = newValue }
    }

    var openInEditorAction: (@MainActor () -> Void)? {
        get { self[OpenInEditorActionKey.self] }
        set { self[OpenInEditorActionKey.self] = newValue }
    }
}
