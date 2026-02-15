//
//  WorkspaceManagerApp.swift
//  WorkspaceManager
//
//  Main entry point - SwiftUI lifecycle with AppKit hooks for window management
//

import SwiftData
import SwiftUI
import WorkspaceManagerCore

@main
struct WorkspaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.newWorkspaceAction) private var newWorkspaceAction

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Repo.self, Workspace.self])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
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
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            SidebarCommands()
        }

        Settings {
            SettingsView()
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidFinishLaunching")

        GhosttyAppManager.shared.initializeIfNeeded()

        // CRITICAL: Ensure app can be activated and brought to front
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("[AppDelegate] Set activation policy to .regular and activated")

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true  // Change to false for background operation
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidBecomeActive")
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

extension FocusedValues {
    var newWorkspaceAction: (@MainActor () -> Void)? {
        get { self[NewWorkspaceActionKey.self] }
        set { self[NewWorkspaceActionKey.self] = newValue }
    }
}
