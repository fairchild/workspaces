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
    @StateObject private var softwareUpdateController: SoftwareUpdateController
    @StateObject private var agentSessionRegistry: AgentSessionRegistry
    @StateObject private var lastCommandStatusRegistry: LastCommandStatusRegistry
    @StateObject private var workspaceStatusAggregator = WorkspaceStatusAggregator()
    @StateObject private var workspaceJournal: WorkspaceJournal
    @StateObject private var claudeIntegrationLifecycle: ClaudeIntegrationLifecycle
    private let appRuntimeDependencies = AppRuntimeDependencies.resolved()
    private let localStateStore: LocalStateStore?
    let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let bootstrap = ModelStoreBootstrapper.bootstrap(
            schema: schema,
            launchEnvironment: ProcessInfo.processInfo.environment
        )
        if ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1" {
            UIFixtureSeeder.seedDataIfNeeded(in: bootstrap.container.mainContext)
        }

        let localStateBootstrap = LocalStateStoreBootstrapper.bootstrap(
            launchEnvironment: ProcessInfo.processInfo.environment
        )
        LocalStateStoreController.shared.apply(localStateBootstrap)
        Task {
            await StartupDiagnosticsStore.shared.attach(localStateStore: localStateBootstrap.store)
        }

        ModelStoreStatusController.shared.apply(bootstrap)
        _appCommandState = StateObject(wrappedValue: AppCommandState())
        _modelStoreStatusController = StateObject(wrappedValue: .shared)
        _softwareUpdateController = StateObject(wrappedValue: SoftwareUpdateController())
        _claudeIntegrationLifecycle = StateObject(wrappedValue: ClaudeIntegrationLifecycle.shared)
        let registry = AgentSessionRegistry(localStateStore: localStateBootstrap.store)
        let commandStatusRegistry = LastCommandStatusRegistry()
        _agentSessionRegistry = StateObject(wrappedValue: registry)
        _lastCommandStatusRegistry = StateObject(wrappedValue: commandStatusRegistry)
        _workspaceJournal = StateObject(wrappedValue: WorkspaceJournal(store: localStateBootstrap.store))
        self.sharedModelContainer = bootstrap.container
        self.localStateStore = localStateBootstrap.store

        // Stand up the hook listener and notification poster on the same registry instance.
        // The listener binds to a Unix socket under Application Support keyed by pid.
        // Disabled in CI to avoid cluttering the runner's filesystem.
        if ProcessInfo.processInfo.environment["CI"] == nil {
            ClaudeIntegrationLifecycle.shared.start(
                registry: registry,
                commandStatusRegistry: commandStatusRegistry
            )
        }
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
            .environmentObject(agentSessionRegistry)
            .environmentObject(lastCommandStatusRegistry)
            .environmentObject(workspaceStatusAggregator)
            .environmentObject(workspaceJournal)
            .environment(\.agentSessionRegistry, agentSessionRegistry)
            .environment(\.lastCommandStatusRegistry, lastCommandStatusRegistry)
            .environment(\.localStateStore, localStateStore)
            .frame(minWidth: 1000, minHeight: 700)
            .onAppear {
                softwareUpdateController.installCheckForUpdatesMenuItem()
            }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1400, height: 900)
        .keyboardShortcut(nil)
        .windowResizability(.contentSize)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    softwareUpdateController.checkForUpdatesWithDisclosure()
                }
                .disabled(!softwareUpdateController.canCheckForUpdates)
            }

            CommandGroup(replacing: .newItem) {
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

                Button("New Terminal Tab") {
                    appCommandState.perform(.newTerminalTab)
                }
                .keyboardShortcut(
                    AppChromeShortcut.newTerminalTab.keyEquivalent,
                    modifiers: AppChromeShortcut.newTerminalTab.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canCreateTerminalTab)

                Button("Close Terminal Tab") {
                    appCommandState.perform(.closeTerminalTab)
                }
                .keyboardShortcut(
                    AppChromeShortcut.closeTerminalTab.keyEquivalent,
                    modifiers: AppChromeShortcut.closeTerminalTab.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canCloseTerminalTab)

                Button("Next Terminal Tab") {
                    appCommandState.perform(.selectNextTerminalTab)
                }
                .keyboardShortcut(
                    AppChromeShortcut.nextTerminalTab.keyEquivalent,
                    modifiers: AppChromeShortcut.nextTerminalTab.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canSelectNextTerminalTab)

                Button("Previous Terminal Tab") {
                    appCommandState.perform(.selectPreviousTerminalTab)
                }
                .keyboardShortcut(
                    AppChromeShortcut.previousTerminalTab.keyEquivalent,
                    modifiers: AppChromeShortcut.previousTerminalTab.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canSelectPreviousTerminalTab)

                Button("Next Terminal Tab") {
                    appCommandState.perform(.selectNextTerminalTab)
                }
                .keyboardShortcut(
                    AppChromeShortcut.alternateNextTerminalTab.keyEquivalent,
                    modifiers: AppChromeShortcut.alternateNextTerminalTab.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canSelectNextTerminalTab)

                Button("Previous Terminal Tab") {
                    appCommandState.perform(.selectPreviousTerminalTab)
                }
                .keyboardShortcut(
                    AppChromeShortcut.alternatePreviousTerminalTab.keyEquivalent,
                    modifiers: AppChromeShortcut.alternatePreviousTerminalTab.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canSelectPreviousTerminalTab)

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

                Button("Switch Workspace...") {
                    appCommandState.perform(.openCommandPalette)
                }
                .keyboardShortcut(
                    AppChromeShortcut.workspaceSwitcher.keyEquivalent,
                    modifiers: AppChromeShortcut.workspaceSwitcher.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canOpenCommandPalette)

                Button("Terminal Theme...") {
                    appCommandState.perform(.openCommandRunner)
                }
                .keyboardShortcut(
                    AppChromeShortcut.commandRunner.keyEquivalent,
                    modifiers: AppChromeShortcut.commandRunner.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canOpenCommandRunner)
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
            SettingsView(softwareUpdateController: softwareUpdateController)
                .environment(\.lumeRuntimeService, appRuntimeDependencies.lumeRuntimeService)
                .environment(\.workspaceProviderRegistry, appRuntimeDependencies.workspaceProviderRegistry)
                .environment(\.claudeSettingsInstaller, claudeIntegrationLifecycle.settingsInstaller)
                .environmentObject(modelStoreStatusController)
                .environmentObject(agentSessionRegistry)
                .environmentObject(lastCommandStatusRegistry)
                .environment(\.agentSessionRegistry, agentSessionRegistry)
                .environment(\.lastCommandStatusRegistry, lastCommandStatusRegistry)
        }
    }
}

private struct MainWindowRootView: View {
    private let appRuntimeDependencies: AppRuntimeDependencies
    @ObservedObject private var appCommandState: AppCommandState
    @State private var deepLinkState = WorkspaceDeepLinkState()
    @AppStorage(MainWindowLastSurface.storageKey) private var lastSurfaceRawValue = ""
    @StateObject private var hostTerminalState = HostTerminalStateStore()
    @StateObject private var workspaceProviderSetupCoordinator = WorkspaceProviderSetupCoordinator()
    @StateObject private var hostLumeSmokeAutomation: HostLumeSmokeAutomationController
    @StateObject private var desktopUISmokeAutomation: DesktopUISmokeAutomationController

    init(
        appRuntimeDependencies: AppRuntimeDependencies,
        appCommandState: AppCommandState
    ) {
        self.appRuntimeDependencies = appRuntimeDependencies
        self._appCommandState = ObservedObject(wrappedValue: appCommandState)
        _hostLumeSmokeAutomation = StateObject(
            wrappedValue: HostLumeSmokeAutomationController()
        )
        _desktopUISmokeAutomation = StateObject(
            wrappedValue: DesktopUISmokeAutomationController()
        )
    }

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            appCommandState: appCommandState,
            hostTerminalState: hostTerminalState,
            workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
            hostLumeSmokeAutomation: hostLumeSmokeAutomation,
            desktopUISmokeAutomation: desktopUISmokeAutomation
        )
        .onOpenURL { url in
            if deepLinkState.enqueue(url: url) {
                NSLog("[DeepLink] Received request: %@", url.absoluteString)
            } else {
                NSLog("[DeepLink] Ignored unsupported URL: %@", url.absoluteString)
            }
        }
        .modifier(AgentSessionRegistryAttacher(hostTerminalState: hostTerminalState))
    }
}

/// Attaches the app-scoped `AgentSessionRegistry` to the host terminal store so the
/// store can register/deregister host sessions with the registry — closes the gap
/// where production POSTs to `/event` had nowhere to land. Also runs the fixture
/// agent-state seeder so deterministic screenshots can land at specific run states.
private struct AgentSessionRegistryAttacher: ViewModifier {
    @EnvironmentObject private var registry: AgentSessionRegistry
    @EnvironmentObject private var commandStatusRegistry: LastCommandStatusRegistry
    @Environment(\.localStateStore) private var localStateStore
    @Environment(\.modelContext) private var modelContext
    let hostTerminalState: HostTerminalStateStore

    func body(content: Content) -> some View {
        content.onAppear {
            hostTerminalState.attach(
                agentSessionRegistry: registry,
                localStateStore: localStateStore,
                hooksSocketPath: ClaudeIntegrationLifecycle.shared.socketPath,
                lastCommandStatusRegistry: commandStatusRegistry
            )
            if ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1" {
                UIFixtureSeeder.seedAgentStatesIfNeeded(
                    from: ProcessInfo.processInfo.environment,
                    in: modelContext,
                    registry: registry,
                    hostTerminalState: hostTerminalState
                )
                UIFixtureSeeder.seedCommandStatusesIfNeeded(
                    from: ProcessInfo.processInfo.environment,
                    in: modelContext,
                    commandStatusRegistry: commandStatusRegistry,
                    hostTerminalState: hostTerminalState
                )
            }
        }
    }
}

// MARK: - AppDelegate for AppKit-level hooks

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowObserver: Any?
    private static let appVariantEnvKey = "WORKSPACES_APP_VARIANT"
    private nonisolated static let disableStateRestorationEnvKey = "WORKSPACES_DISABLE_STATE_RESTORATION"

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

    private var disablesStateRestoration: Bool {
        !Self.shouldPreserveState(launchEnvironment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func shouldPreserveState(launchEnvironment: [String: String]) -> Bool {
        launchEnvironment[disableStateRestorationEnvKey] != "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidFinishLaunching")
        PerformanceSignposts.beginLaunchToFirstPromptIfNeeded()

        GhosttyAppManager.shared.initializeIfNeeded()

        if isCI {
            // CI: fully invisible — no dock icon, no app-switcher, no focus steal.
            NSApp.setActivationPolicy(.accessory)
            NSLog("[AppDelegate] CI detected: .accessory policy (background)")
        } else {
            // Shared-desktop mode keeps .regular policy + dock presence but
            // suppresses every NSApp.activate call (launch and runtime), via
            // AppActivationPolicy. See WORKSPACES_NO_ACTIVATE_ON_LAUNCH.
            NSApp.setActivationPolicy(.regular)
            AppActivationPolicy.shared.activateIfAllowed()
            NSLog(
                "[AppDelegate] activation policy=.regular allowsActivation=\(AppActivationPolicy.shared.allowsActivation)"
            )
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

    func application(_ application: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        !disablesStateRestoration
    }

    func application(_ application: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        !disablesStateRestoration
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        !disablesStateRestoration
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        !disablesStateRestoration
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

private struct AgentSessionRegistryKey: EnvironmentKey {
    static let defaultValue: AgentSessionRegistry? = nil
}

private struct LastCommandStatusRegistryKey: EnvironmentKey {
    static let defaultValue: LastCommandStatusRegistry? = nil
}

private struct LocalStateStoreKey: EnvironmentKey {
    static let defaultValue: LocalStateStore? = nil
}

private struct ClaudeSettingsInstallerKey: EnvironmentKey {
    static let defaultValue: (any ClaudeSettingsInstalling)? = nil
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

    var agentSessionRegistry: AgentSessionRegistry? {
        get { self[AgentSessionRegistryKey.self] }
        set { self[AgentSessionRegistryKey.self] = newValue }
    }

    var lastCommandStatusRegistry: LastCommandStatusRegistry? {
        get { self[LastCommandStatusRegistryKey.self] }
        set { self[LastCommandStatusRegistryKey.self] = newValue }
    }

    var localStateStore: LocalStateStore? {
        get { self[LocalStateStoreKey.self] }
        set { self[LocalStateStoreKey.self] = newValue }
    }

    var claudeSettingsInstaller: (any ClaudeSettingsInstalling)? {
        get { self[ClaudeSettingsInstallerKey.self] }
        set { self[ClaudeSettingsInstallerKey.self] = newValue }
    }
}

struct MainWindowFocusedActions {
    typealias Action = @MainActor () -> Void

    var toggleSidebar: Action? = nil
    var toggleInspector: Action? = nil
    var toggleTerminalPanel: Action? = nil
    var newTerminalTab: Action? = nil
    var closeTerminalTab: Action? = nil
    var selectNextTerminalTab: Action? = nil
    var selectPreviousTerminalTab: Action? = nil
    var openInEditor: Action? = nil
    var openInBrowser: Action? = nil
    var reloadWebSource: Action? = nil
    var openDesktop: Action? = nil
    var revealInFinder: Action? = nil
    var copyPath: Action? = nil
    var openCommandPalette: Action? = nil
    var openCommandRunner: Action? = nil

    @MainActor static let empty = MainWindowFocusedActions()
}

struct MainWindowCommandAvailability: Equatable {
    let canToggleSidebar: Bool
    let canToggleInspector: Bool
    let canToggleTerminalPanel: Bool
    let canCreateTerminalTab: Bool
    let canCloseTerminalTab: Bool
    let canSelectNextTerminalTab: Bool
    let canSelectPreviousTerminalTab: Bool
    let canOpenInEditor: Bool
    let canOpenInBrowser: Bool
    let canReloadWebSource: Bool
    let canOpenDesktop: Bool
    let canRevealInFinder: Bool
    let canCopyPath: Bool
    let canOpenCommandPalette: Bool
    let canOpenCommandRunner: Bool

    static let empty = MainWindowCommandAvailability(
        canToggleSidebar: false,
        canToggleInspector: false,
        canToggleTerminalPanel: false,
        canCreateTerminalTab: false,
        canCloseTerminalTab: false,
        canSelectNextTerminalTab: false,
        canSelectPreviousTerminalTab: false,
        canOpenInEditor: false,
        canOpenInBrowser: false,
        canReloadWebSource: false,
        canOpenDesktop: false,
        canRevealInFinder: false,
        canCopyPath: false,
        canOpenCommandPalette: false,
        canOpenCommandRunner: false
    )
}

enum MainWindowCommand {
    case toggleSidebar
    case toggleInspector
    case toggleTerminalPanel
    case newTerminalTab
    case closeTerminalTab
    case selectNextTerminalTab
    case selectPreviousTerminalTab
    case openInEditor
    case openInBrowser
    case reloadWebSource
    case openDesktop
    case revealInFinder
    case copyPath
    case openCommandPalette
    case openCommandRunner
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
        case .newTerminalTab:
            mainWindowActions.newTerminalTab?()
        case .closeTerminalTab:
            mainWindowActions.closeTerminalTab?()
        case .selectNextTerminalTab:
            mainWindowActions.selectNextTerminalTab?()
        case .selectPreviousTerminalTab:
            mainWindowActions.selectPreviousTerminalTab?()
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
        case .openCommandPalette:
            mainWindowActions.openCommandPalette?()
        case .openCommandRunner:
            mainWindowActions.openCommandRunner?()
        }
    }
}
