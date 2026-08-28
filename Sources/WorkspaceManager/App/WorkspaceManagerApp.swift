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
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceManagerApp")

extension Notification.Name {
    static let showFeedbackSheet = Notification.Name("WorkspacesShowFeedbackSheet")
}

@main
struct WorkspaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appCommandState: AppCommandState
    @StateObject private var modelStoreStatusController: ModelStoreStatusController
    @StateObject private var softwareUpdateController: SoftwareUpdateController
    @StateObject private var agentSessionRegistry: AgentSessionRegistry
    @StateObject private var lastCommandStatusRegistry: LastCommandStatusRegistry
    // Deliberately not a @StateObject: an App-level @StateObject subscription
    // re-evaluates the Scene body (and so the whole window tree) on every
    // publish. The aggregator publishes per status-aggregation window; views
    // that render its state subscribe where they render it (#1347).
    private let workspaceStatusAggregator = WorkspaceStatusAggregator()
    @StateObject private var workspaceJournal: WorkspaceJournal
    @StateObject private var claudeIntegrationLifecycle: ClaudeIntegrationLifecycle
    private let appRuntimeDependencies: AppRuntimeDependencies
    private let localStateStore: LocalStateStore?
    let sharedModelContainer: ModelContainer

    init() {
        // Resolving the preferences domain — and wiping it, when the run is
        // isolated — has to happen before anything reads a stored value through it,
        // which is why it is the first statement of this body and why nothing that
        // reads preferences carries an inline stored-property default. Inline
        // defaults are evaluated in the initializer prologue, ahead of this line:
        // `AppRuntimeDependencies.resolved()` reads the web-next settings out of
        // UserDefaults, so as a stored-property default it would have observed the
        // pre-wipe suite. It is constructed below instead.
        LaunchPreferences.bootstrapForApplicationLaunch()
        self.appRuntimeDependencies = AppRuntimeDependencies.resolved()

        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let bootstrap = ModelStoreBootstrapper.bootstrap(
            schema: schema,
            launchEnvironment: ProcessInfo.processInfo.environment
        )
        #if DEBUG
            if ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1" {
                UIFixtureSeeder.seedDataIfNeeded(in: bootstrap.container.mainContext)
                UIFixtureSeeder.seedPinnedWorkspacesIfNeeded(
                    from: ProcessInfo.processInfo.environment,
                    in: bootstrap.container.mainContext
                )
            }
        #endif

        let localStateBootstrap = LocalStateStoreBootstrapper.bootstrap(
            launchEnvironment: ProcessInfo.processInfo.environment
        )
        LocalStateStoreController.shared.apply(localStateBootstrap)
        // Seeded only after the primary store above has already opened and migrated on this
        // same database file — starting it first would race that migration on a fresh data
        // dir (two GRDB pools altering schema concurrently). Also only fires when the primary
        // store is actually active: fixture mode without an explicit data directory disables
        // the primary store (see LocalStateStoreBootstrapper.bootstrap), and seeding anyway
        // would silently write a synthetic row into a real user's production database instead
        // of the isolated fixture one.
        #if DEBUG
            if ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1",
                localStateBootstrap.store != nil
            {
                UIFixtureContinuitySeeder.seedIfNeeded()
            }
        #endif
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
                appCommandState: appCommandState,
                workspaceStatusAggregator: workspaceStatusAggregator
            )
            .environment(\.lumeRuntimeService, appRuntimeDependencies.lumeRuntimeService)
            .environment(
                \.workspaceProviderRegistry,
                appRuntimeDependencies.workspaceProviderRegistry
            )
            .environment(\.webNextServerService, appRuntimeDependencies.webNextServerService)
            .environmentObject(modelStoreStatusController)
            .environmentObject(agentSessionRegistry)
            .environmentObject(lastCommandStatusRegistry)
            .environmentObject(workspaceStatusAggregator)
            .environmentObject(workspaceJournal)
            .environment(\.agentSessionRegistry, agentSessionRegistry)
            .environment(\.lastCommandStatusRegistry, lastCommandStatusRegistry)
            .environment(\.localStateStore, localStateStore)
            .defaultAppStorage(LaunchPreferences.defaults)
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
        .windowToolbarStyle(
            .unifiedCompact(
                showsTitle: MainWindowPresentationController.showsVisualWindowTitle
            )
        )
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

                Button("Switch Session...") {
                    appCommandState.perform(.openSessionSwitcher)
                }
                .keyboardShortcut(
                    AppChromeShortcut.workspaceSwitcher.keyEquivalent,
                    modifiers: AppChromeShortcut.workspaceSwitcher.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canOpenSessionSwitcher)

                Button("Terminal Theme...") {
                    appCommandState.perform(.openCommandRunner)
                }
                .keyboardShortcut(
                    AppChromeShortcut.commandRunner.keyEquivalent,
                    modifiers: AppChromeShortcut.commandRunner.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canOpenCommandRunner)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appCommandState.performSaveDocument()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appCommandState.canSaveDocument)
            }

            SidebarCommands()

            CommandMenu("Selection") {
                Button("Open Web Session") {
                    appCommandState.perform(.openEmbeddedWebNext)
                }
                .keyboardShortcut(
                    AppChromeShortcut.openEmbeddedWebNext.keyEquivalent,
                    modifiers: AppChromeShortcut.openEmbeddedWebNext.eventModifiers
                )
                .disabled(!appCommandState.mainWindowAvailability.canOpenEmbeddedWebNext)

                Divider()

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
                KeyboardShortcutsMenuItem()

                SessionHistoryMenuItem()

                Button("Send Feedback...") {
                    appCommandState.perform(.sendFeedback)
                }
                .disabled(!appCommandState.mainWindowAvailability.canSendFeedback)

                Button("Export Diagnostic Report...") {
                    Task {
                        await DiagnosticReportExporter.exportWithSavePanel()
                    }
                }
            }
        }

        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
                .defaultAppStorage(LaunchPreferences.defaults)
        }
        .windowResizability(.contentSize)

        Window("Session History", id: SessionHistoryView.windowID) {
            SessionHistoryView(store: localStateStore)
                .defaultAppStorage(LaunchPreferences.defaults)
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
                .defaultAppStorage(LaunchPreferences.defaults)
        }
    }
}

/// Help-menu entry that opens the keyboard-shortcut cheat-sheet window. A small view so it can hold
/// the `openWindow` environment action the surrounding `App` body cannot.
private struct KeyboardShortcutsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") {
            openWindow(id: KeyboardShortcutsView.windowID)
        }
    }
}

/// Help-menu entry that opens the session history browser window.
private struct SessionHistoryMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Session History") {
            openWindow(id: SessionHistoryView.windowID)
        }
    }
}

private struct MainWindowRootView: View {
    private let appRuntimeDependencies: AppRuntimeDependencies
    private let workspaceStatusAggregator: WorkspaceStatusAggregator
    @ObservedObject private var appCommandState: AppCommandState
    @State private var deepLinkState = WorkspaceDeepLinkState()
    // Bound to the resolved store explicitly: the restored surface is the state an
    // isolated launch must not inherit, so it does not depend on `defaultAppStorage`
    // reaching this declaration through the environment.
    @AppStorage(MainWindowLastSurface.storageKey, store: LaunchPreferences.defaults)
    private var lastSurfaceRawValue = ""
    @StateObject private var tileTreeStore = TileTreeStore()
    @StateObject private var workspaceProviderSetupCoordinator = WorkspaceProviderSetupCoordinator()
    @StateObject private var smokeDriver = SmokeScenarioDriver()

    init(
        appRuntimeDependencies: AppRuntimeDependencies,
        appCommandState: AppCommandState,
        workspaceStatusAggregator: WorkspaceStatusAggregator
    ) {
        self.appRuntimeDependencies = appRuntimeDependencies
        self._appCommandState = ObservedObject(wrappedValue: appCommandState)
        self.workspaceStatusAggregator = workspaceStatusAggregator
    }

    var body: some View {
        ContentView(
            deepLinkState: $deepLinkState,
            lastSurfaceRawValue: $lastSurfaceRawValue,
            appCommandState: appCommandState,
            tileTreeStore: tileTreeStore,
            workspaceProviderSetupCoordinator: workspaceProviderSetupCoordinator,
            smokeDriver: smokeDriver,
            workspaceStatusAggregator: workspaceStatusAggregator
        )
        .onOpenURL { url in
            if deepLinkState.enqueue(url: url) {
                log.info("[DeepLink] Received request: \(url.absoluteString, privacy: .public)")
            } else {
                log.info("[DeepLink] Ignored unsupported URL: \(url.absoluteString, privacy: .public)")
            }
        }
        .modifier(AgentSessionRegistryAttacher(tileTreeStore: tileTreeStore))
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
    let tileTreeStore: TileTreeStore

    func body(content: Content) -> some View {
        content.onAppear {
            tileTreeStore.attach(
                agentSessionRegistry: registry,
                localStateStore: localStateStore,
                hooksSocketPath: ClaudeIntegrationLifecycle.shared.socketPath,
                lastCommandStatusRegistry: commandStatusRegistry
            )
            #if DEBUG
                if ProcessInfo.processInfo.environment["WORKSPACES_UI_FIXTURE"] == "1" {
                    UIFixtureSeeder.seedAgentStatesIfNeeded(
                        from: ProcessInfo.processInfo.environment,
                        in: modelContext,
                        registry: registry,
                        tileTreeStore: tileTreeStore
                    )
                    UIFixtureSeeder.seedCommandStatusesIfNeeded(
                        from: ProcessInfo.processInfo.environment,
                        in: modelContext,
                        commandStatusRegistry: commandStatusRegistry,
                        tileTreeStore: tileTreeStore
                    )
                }
            #endif
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
        log.info("[AppDelegate] applicationDidFinishLaunching")
        PerformanceSignposts.beginLaunchToFirstPromptIfNeeded()

        GhosttyAppManager.shared.initializeIfNeeded()

        if isCI {
            // CI: fully invisible — no dock icon, no app-switcher, no focus steal.
            NSApp.setActivationPolicy(.accessory)
            log.info("[AppDelegate] CI detected: .accessory policy (background)")
        } else {
            // Shared-desktop mode keeps .regular policy + dock presence but
            // suppresses every NSApp.activate call (launch and runtime), via
            // AppActivationPolicy. See WORKSPACES_NO_ACTIVATE_ON_LAUNCH.
            NSApp.setActivationPolicy(.regular)
            AppActivationPolicy.shared.activateIfAllowed()
            log.info(
                "[AppDelegate] activation policy=.regular allowsActivation=\(AppActivationPolicy.shared.allowsActivation, privacy: .public)"
            )
        }
        // Applying after activation-policy setup avoids Dock showing the generic executable icon.
        applyApplicationIconIfAvailable()
        applyVariantPresentationIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.installHelpMenuItems()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.installHelpMenuItems()
        }

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
            let window = notification.object as? NSWindow
            Task { @MainActor in
                if let window {
                    TerminalFocusManager.shared.registerWindow(window)
                }
            }
        }
    }

    private func installHelpMenuItems() {
        guard let helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu else { return }

        if helpMenu.item(withTitle: "Send Feedback...") == nil {
            helpMenu.addItem(.separator())
            let item = NSMenuItem(
                title: "Send Feedback...",
                action: #selector(showFeedbackFromHelpMenu),
                keyEquivalent: ""
            )
            item.target = self
            helpMenu.addItem(item)
        }

        if helpMenu.item(withTitle: "Export Diagnostic Report...") == nil {
            let item = NSMenuItem(
                title: "Export Diagnostic Report...",
                action: #selector(exportDiagnosticReportFromHelpMenu),
                keyEquivalent: ""
            )
            item.target = self
            helpMenu.addItem(item)
        }
    }

    @objc private func showFeedbackFromHelpMenu() {
        NotificationCenter.default.post(name: .showFeedbackSheet, object: nil)
    }

    @objc private func exportDiagnosticReportFromHelpMenu() {
        Task {
            await DiagnosticReportExporter.exportWithSavePanel()
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

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the embedded web-next server's process group so quitting
        // never orphans a `next start` child holding the loopback port. No-op
        // when the surface was never activated.
        WebNextServerLifecycle.shared.stopBlocking()
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
        log.info("[AppDelegate] applicationDidBecomeActive")
        // The operator credential can be removed — or left stale — underneath a running app, and
        // nothing tells the app it happened (#1391). Activation is the moment to re-check: when
        // everything is already healthy the reuse path is a load and a comparison.
        AutomationIntegrationLifecycle.shared.refreshOperatorCredentialOnActivation()
        installHelpMenuItems()
        applyApplicationIconIfAvailable()
        GhosttyAppManager.shared.setFocus(true)
        TerminalFocusManager.shared.appDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        log.info("[AppDelegate] applicationDidResignActive")
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

private struct FeedbackServiceKey: EnvironmentKey {
    static let defaultValue: any FeedbackServiceProtocol = FeedbackService.shared
}

private struct WebNextServerServiceKey: EnvironmentKey {
    static let defaultValue: any WebNextServerServiceProtocol = WebNextServerService(
        configuration: WebNextServerSettings.resolvedConfiguration()
    )
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

    var feedbackService: any FeedbackServiceProtocol {
        get { self[FeedbackServiceKey.self] }
        set { self[FeedbackServiceKey.self] = newValue }
    }

    var webNextServerService: any WebNextServerServiceProtocol {
        get { self[WebNextServerServiceKey.self] }
        set { self[WebNextServerServiceKey.self] = newValue }
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
    var openSessionSwitcher: Action? = nil
    var openCommandRunner: Action? = nil
    var sendFeedback: Action? = nil
    var openEmbeddedWebNext: Action? = nil

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
    let canOpenSessionSwitcher: Bool
    let canOpenCommandRunner: Bool
    let canSendFeedback: Bool
    let canOpenEmbeddedWebNext: Bool

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
        canOpenSessionSwitcher: false,
        canOpenCommandRunner: false,
        canSendFeedback: false,
        canOpenEmbeddedWebNext: false
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
    case openSessionSwitcher
    case openCommandRunner
    case sendFeedback
    case openEmbeddedWebNext
}

@MainActor
final class AppCommandState: ObservableObject {
    @Published private(set) var canCreateWorkspace = false
    @Published private(set) var canSaveDocument = false
    /// True while the open editor document has unsaved edits, so navigation intents can pause for
    /// a Save / Discard / Cancel prompt (#704 Phase 4).
    @Published private(set) var hasUnsavedDocumentEdits = false
    @Published private(set) var mainWindowAvailability = MainWindowCommandAvailability.empty

    private var newWorkspaceAction: (@MainActor () -> Void)?
    private var saveDocumentAction: (@MainActor () -> Void)?
    private var saveDocumentAsyncAction: (@MainActor () async -> Bool)?
    private var mainWindowActions = MainWindowFocusedActions.empty

    func setNewWorkspaceAction(_ action: (@MainActor () -> Void)?) {
        newWorkspaceAction = action
        let nextAvailability = action != nil
        guard canCreateWorkspace != nextAvailability else { return }
        canCreateWorkspace = nextAvailability
    }

    func setSaveDocumentAction(_ action: (@MainActor () -> Void)?, isEnabled: Bool) {
        saveDocumentAction = action
        let nextAvailability = action != nil && isEnabled
        guard canSaveDocument != nextAvailability else { return }
        canSaveDocument = nextAvailability
    }

    func clearSaveDocumentAction() {
        setSaveDocumentAction(nil, isEnabled: false)
    }

    /// Register the open document's dirty state and the awaiting-Save hook the navigation guard
    /// uses. (Discarding needs no hook: navigating away replaces the buffer, abandoning edits.)
    func setDocumentEditsState(isDirty: Bool, save: (@MainActor () async -> Bool)?) {
        saveDocumentAsyncAction = save
        guard hasUnsavedDocumentEdits != isDirty else { return }
        hasUnsavedDocumentEdits = isDirty
    }

    func clearDocumentEditsState() {
        saveDocumentAsyncAction = nil
        guard hasUnsavedDocumentEdits else { return }
        hasUnsavedDocumentEdits = false
    }

    /// Save the dirty document, returning whether the save succeeded. No registered hook (or no
    /// unsaved edits) counts as success so navigation proceeds.
    @discardableResult
    func saveDirtyDocument() async -> Bool {
        guard let saveDocumentAsyncAction else { return true }
        return await saveDocumentAsyncAction()
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

    func performSaveDocument() {
        guard canSaveDocument else { return }
        saveDocumentAction?()
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
        case .openSessionSwitcher:
            mainWindowActions.openSessionSwitcher?()
        case .openCommandRunner:
            mainWindowActions.openCommandRunner?()
        case .sendFeedback:
            mainWindowActions.sendFeedback?()
        case .openEmbeddedWebNext:
            mainWindowActions.openEmbeddedWebNext?()
        }
    }
}
