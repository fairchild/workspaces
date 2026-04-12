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
    @StateObject private var appCommandState: AppCommandState
    @StateObject private var modelStoreStatusController: ModelStoreStatusController
    private let appRuntimeDependencies = AppRuntimeDependencies.resolved()
    let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let bootstrap = ModelStoreBootstrapper.bootstrap(
            schema: schema,
            launchEnvironment: ProcessInfo.processInfo.environment
        )
        if ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1" {
            seedUIFixtureDataIfNeeded(in: bootstrap.container.mainContext)
        }

        ModelStoreStatusController.shared.apply(bootstrap)
        _appCommandState = StateObject(wrappedValue: AppCommandState())
        _modelStoreStatusController = StateObject(wrappedValue: .shared)
        self.sharedModelContainer = bootstrap.container
    }

    var body: some Scene {
        WindowGroup {
            MainWindowRootView(
                appRuntimeDependencies: appRuntimeDependencies,
                appCommandState: appCommandState
            )
            .environment(\.lumeRuntimeService, appRuntimeDependencies.lumeRuntimeService)
            .environment(
                \.workspaceProviderRegistry,
                appRuntimeDependencies.workspaceProviderRegistry
            )
            .environmentObject(modelStoreStatusController)
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
                    appCommandState.performNewWorkspace()
                }
                .keyboardShortcut(
                    AppChromeShortcut.newWorkspace.keyEquivalent,
                    modifiers: AppChromeShortcut.newWorkspace.eventModifiers
                )
                .disabled(!appCommandState.canCreateWorkspace)

                Button("Open in...") {
                    appCommandState.perform(.openInEditor)
                }
                .keyboardShortcut(
                    AppChromeShortcut.openInEditor.keyEquivalent,
                    modifiers: AppChromeShortcut.openInEditor.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canOpenInEditor)

                Button("Toggle Sidebar") {
                    appCommandState.perform(.toggleSidebar)
                }
                .keyboardShortcut(
                    AppChromeShortcut.toggleSidebar.keyEquivalent,
                    modifiers: AppChromeShortcut.toggleSidebar.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canToggleSidebar)

                Button("Toggle Inspector") {
                    appCommandState.perform(.toggleInspector)
                }
                .keyboardShortcut(
                    AppChromeShortcut.toggleInspector.keyEquivalent,
                    modifiers: AppChromeShortcut.toggleInspector.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canToggleInspector)

                Button("Toggle Terminal Panel") {
                    appCommandState.perform(.toggleTerminalPanel)
                }
                .keyboardShortcut(
                    AppChromeShortcut.toggleTerminalPanel.keyEquivalent,
                    modifiers: AppChromeShortcut.toggleTerminalPanel.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canToggleTerminalPanel)
            }

            SidebarCommands()

            CommandMenu("Selection") {
                Button("Open in Browser") {
                    appCommandState.perform(.openInBrowser)
                }
                .disabled(!appCommandState.mainWindowAvailability.canOpenInBrowser)

                Button("Reload Web Source") {
                    appCommandState.perform(.reloadWebSource)
                }
                .disabled(!appCommandState.mainWindowAvailability.canReloadWebSource)

                Divider()

                Button("Open Desktop") {
                    appCommandState.perform(.openDesktop)
                }
                .disabled(!appCommandState.mainWindowAvailability.canOpenDesktop)

                Button("Reveal in Finder") {
                    appCommandState.perform(.revealInFinder)
                }
                .disabled(!appCommandState.mainWindowAvailability.canRevealInFinder)

                Button("Copy Path") {
                    appCommandState.perform(.copyPath)
                }
                .disabled(!appCommandState.mainWindowAvailability.canCopyPath)
            }

            CommandGroup(after: .help) {
                Button("Export Diagnostic Report...") {
                    Task {
                        await DiagnosticReportExporter.exportWithSavePanel()
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(\.lumeRuntimeService, appRuntimeDependencies.lumeRuntimeService)
                .environment(\.workspaceProviderRegistry, appRuntimeDependencies.workspaceProviderRegistry)
                .environmentObject(modelStoreStatusController)
        }
    }
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
    @ObservedObject private var appCommandState: AppCommandState
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @SceneStorage(MainWindowLastSurface.storageKey) private var lastSurfaceRawValue = ""
    @StateObject private var hostTerminalState = HostTerminalStateStore()
    @StateObject private var workspaceProviderSetupCoordinator = WorkspaceProviderSetupCoordinator()
    @StateObject private var hostLumeSmokeAutomation: HostLumeSmokeAutomationController

    init(
        appRuntimeDependencies: AppRuntimeDependencies,
        appCommandState: AppCommandState
    ) {
        self.appRuntimeDependencies = appRuntimeDependencies
        self._appCommandState = ObservedObject(wrappedValue: appCommandState)
        _hostLumeSmokeAutomation = StateObject(
            wrappedValue: HostLumeSmokeAutomationController()
        )
    }

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            appCommandState: appCommandState,
            hostTerminalState: hostTerminalState,
            workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
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
        TerminalFocusManager.shared.appDidBecomeActive()
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

struct MainWindowFocusedActions {
    typealias Action = @MainActor () -> Void

    var toggleSidebar: Action? = nil
    var toggleInspector: Action? = nil
    var toggleTerminalPanel: Action? = nil
    var openInEditor: Action? = nil
    var openInBrowser: Action? = nil
    var reloadWebSource: Action? = nil
    var openDesktop: Action? = nil
    var revealInFinder: Action? = nil
    var copyPath: Action? = nil

    static let empty = MainWindowFocusedActions()
}

struct MainWindowCommandAvailability: Equatable {
    let canToggleSidebar: Bool
    let canToggleInspector: Bool
    let canToggleTerminalPanel: Bool
    let canOpenInEditor: Bool
    let canOpenInBrowser: Bool
    let canReloadWebSource: Bool
    let canOpenDesktop: Bool
    let canRevealInFinder: Bool
    let canCopyPath: Bool

    static let empty = MainWindowCommandAvailability(
        canToggleSidebar: false,
        canToggleInspector: false,
        canToggleTerminalPanel: false,
        canOpenInEditor: false,
        canOpenInBrowser: false,
        canReloadWebSource: false,
        canOpenDesktop: false,
        canRevealInFinder: false,
        canCopyPath: false
    )
}

enum MainWindowCommand {
    case toggleSidebar
    case toggleInspector
    case toggleTerminalPanel
    case openInEditor
    case openInBrowser
    case reloadWebSource
    case openDesktop
    case revealInFinder
    case copyPath
}

@MainActor
final class AppCommandState: ObservableObject {
    @Published private(set) var canCreateWorkspace = false
    @Published private(set) var mainWindowAvailability = MainWindowCommandAvailability.empty

    private var newWorkspaceAction: (@MainActor () -> Void)?
    private var mainWindowActions = MainWindowFocusedActions.empty

    func setNewWorkspaceAction(_ action: (@MainActor () -> Void)?) {
        newWorkspaceAction = action
        let nextAvailability = action != nil
        guard canCreateWorkspace != nextAvailability else { return }
        canCreateWorkspace = nextAvailability
    }

    func setMainWindowActions(
        _ actions: MainWindowFocusedActions,
        availability: MainWindowCommandAvailability
    ) {
        mainWindowActions = actions
        guard mainWindowAvailability != availability else { return }
        mainWindowAvailability = availability
    }

    func clearMainWindowActions() {
        setMainWindowActions(.empty, availability: .empty)
    }

    func performNewWorkspace() {
        newWorkspaceAction?()
    }

    func perform(_ command: MainWindowCommand) {
        switch command {
        case .toggleSidebar:
            mainWindowActions.toggleSidebar?()
        case .toggleInspector:
            mainWindowActions.toggleInspector?()
        case .toggleTerminalPanel:
            mainWindowActions.toggleTerminalPanel?()
        case .openInEditor:
            mainWindowActions.openInEditor?()
        case .openInBrowser:
            mainWindowActions.openInBrowser?()
        case .reloadWebSource:
            mainWindowActions.reloadWebSource?()
        case .openDesktop:
            mainWindowActions.openDesktop?()
        case .revealInFinder:
            mainWindowActions.revealInFinder?()
        case .copyPath:
            mainWindowActions.copyPath?()
        }
    }
}
