//
//  TerminalView.swift
//  WorkspaceManager
//
//  Pure AppKit terminal via NSViewControllerRepresentable
//

import SwiftTerm
import SwiftUI
import WorkspaceManagerCore

// MARK: - Terminal Container (SwiftUI wrapper)

struct TerminalContainerView: View {
    let workspace: Workspace
    @State private var terminalKey = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // Terminal header bar (SwiftUI - no focus issues here)
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)

                Text(workspace.workspaceURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Button {
                    terminalKey = UUID()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart Terminal")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Terminal view - pure AppKit via NSViewControllerRepresentable
            TerminalViewControllerRepresentable(
                workingDirectory: workspace.workspaceURL,
                onProcessExit: {
                    NSLog("[Terminal] Process exited for workspace: %@", workspace.name)
                }
            )
            .id(terminalKey)
        }
    }
}

// MARK: - NSViewControllerRepresentable (bridges AppKit VC to SwiftUI)

struct TerminalViewControllerRepresentable: NSViewControllerRepresentable {
    let workingDirectory: URL
    var onProcessExit: (() -> Void)?

    func makeNSViewController(context: Context) -> TerminalViewController {
        NSLog("[TerminalVC] Creating for: %@", workingDirectory.lastPathComponent)
        let vc = TerminalViewController()
        vc.workingDirectory = workingDirectory
        vc.onProcessExit = onProcessExit
        return vc
    }

    func updateNSViewController(_ nsViewController: TerminalViewController, context: Context) {
        // No updates needed - terminal is stateful
    }
}

// MARK: - Terminal View Controller (Pure AppKit)

class TerminalViewController: NSViewController, LocalProcessTerminalViewDelegate {

    var workingDirectory: URL?
    var onProcessExit: (() -> Void)?

    private(set) var terminalView: LocalProcessTerminalView!
    private let viewId = UUID().uuidString.prefix(8)
    private var eventMonitor: Any?

    override func loadView() {
        // Create a container view that will forward clicks to the terminal
        let container = TerminalNSContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Create terminal view
        terminalView = LocalProcessTerminalView(frame: container.bounds)
        terminalView.processDelegate = self
        terminalView.autoresizingMask = [.width, .height]

        // Configure appearance
        configureAppearance()

        // Add terminal to container
        container.addSubview(terminalView)
        container.terminalView = terminalView

        // Set container as the view
        self.view = container

        NSLog("[TerminalVC %@] loadView complete", String(viewId))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[TerminalVC %@] viewDidLoad", String(viewId))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        NSLog("[TerminalVC %@] viewWillAppear", String(viewId))

        // Start shell when view appears
        startShell()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NSLog("[TerminalVC %@] viewWillDisappear", String(viewId))

        // Clean up event monitor to prevent duplicates if view is reused
        removeEventMonitor()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NSLog("[TerminalVC %@] viewDidAppear, requesting focus", String(viewId))

        // Register window with focus manager
        if let window = view.window {
            TerminalFocusManager.shared.registerWindow(window)
        }

        // Request focus with retry logic (Ghostty-style)
        TerminalFocusManager.shared.requestFocus(for: terminalView)

        // Install event monitor for edge cases only
        setupEventMonitor()
    }

    /// Event monitor to intercept keyboard events before SwiftUI.
    /// Required because NSViewControllerRepresentable doesn't properly forward keyDown.
    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }

        NSLog("[TerminalVC %@] Installing keyboard event monitor", String(viewId))

        // SwiftUI intercepts keyDown before it reaches NSView, so we must use an event monitor
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]
        ) { [weak self] event in
            self?.handleLocalEvent(event)
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        // Log ALL events for debugging
        if event.type == .keyDown {
            NSLog(
                "[TerminalVC %@] LOCAL EVENT keyDown: '%@' - isActive:%@ isKey:%@ FR:%@",
                String(viewId),
                event.characters ?? "?",
                NSApp.isActive ? "YES" : "NO",
                terminalView.window?.isKeyWindow == true ? "YES" : "NO",
                String(describing: type(of: terminalView.window?.firstResponder ?? NSObject())))
        }

        guard let window = terminalView.window,
            window.isKeyWindow
        else {
            return event
        }

        switch event.type {
        case .leftMouseDown:
            // Click-to-focus: if click is in our terminal, ensure we get focus
            let locationInTerminal = terminalView.convert(event.locationInWindow, from: nil)
            if terminalView.bounds.contains(locationInTerminal) {
                if window.firstResponder !== terminalView {
                    NSLog("[TerminalVC %@] Click-to-focus triggered", String(viewId))
                    TerminalFocusManager.shared.requestFocus(for: terminalView)
                }
            }
            return event  // Don't consume - let normal click handling proceed

        case .keyDown:
            // Forward keyDown to terminal if it's the focused terminal
            if window.firstResponder === terminalView,
                TerminalFocusManager.shared.focusedTerminal === terminalView
            {
                terminalView.keyDown(with: event)
                return nil  // Consume - don't let SwiftUI handle it
            }
            return event

        case .keyUp:
            if window.firstResponder === terminalView {
                terminalView.keyUp(with: event)
                return nil
            }
            return event

        case .flagsChanged:
            if window.firstResponder === terminalView {
                terminalView.flagsChanged(with: event)
                return nil
            }
            return event

        default:
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSLog("[TerminalVC %@] Removing event monitor", String(viewId))
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Focus Handling

    func requestFocus() {
        TerminalFocusManager.shared.requestFocus(for: terminalView)
    }

    // MARK: - Terminal Configuration

    private func configureAppearance() {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let theme = TerminalTheme.defaultDark
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.nativeBackgroundColor = theme.background
        terminalView.caretColor = theme.cursor
    }

    private func startShell() {
        guard let workingDirectory = workingDirectory else {
            NSLog("[TerminalVC %@] No working directory set", String(viewId))
            return
        }

        NSLog("[TerminalVC %@] Starting shell in: %@", String(viewId), workingDirectory.path)

        // Build environment
        var envDict = ProcessInfo.processInfo.environment
        envDict["TERM"] = "xterm-256color"
        envDict["COLORTERM"] = "truecolor"
        envDict["LANG"] = "en_US.UTF-8"

        if let path = envDict["PATH"] {
            envDict["PATH"] = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                path,
            ].joined(separator: ":")
        }

        let shell = envDict["SHELL"] ?? "/bin/zsh"
        let environment = envDict.map { "\($0.key)=\($0.value)" }

        // Start the process
        terminalView.startProcess(
            executable: shell,
            args: ["--login"],
            environment: environment,
            execName: URL(fileURLWithPath: shell).lastPathComponent
        )

        // Change to workspace directory
        let escapedPath = workingDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
        terminalView.send(txt: "cd '\(escapedPath)' && clear\n")
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        NSLog("[TerminalVC %@] Process terminated with code: %d", String(viewId), exitCode ?? -1)
        DispatchQueue.main.async { [weak self] in
            self?.onProcessExit?()
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        NSLog("[TerminalVC %@] Size changed: %dx%d", String(viewId), newCols, newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update window title here
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        // Current directory changed
    }

    deinit {
        NSLog("[TerminalVC %@] deinit", String(viewId))
        removeEventMonitor()
    }
}
