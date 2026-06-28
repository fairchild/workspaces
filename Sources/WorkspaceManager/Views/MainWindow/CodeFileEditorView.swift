//
//  CodeFileEditorView.swift
//  WorkspaceManager
//
//  In-app editor for a workspace file: a plain editor (`edit`) or an editable diff against
//  HEAD with per-hunk accept/reject (`reviewDiff`), rendered by the embedded CodeMirror bundle.
//  Owns save, unsaved-change confirmation, and agent-vs-human on-disk conflict handling.
//

import AppKit
import CryptoKit
import SwiftUI
import WorkspaceManagerCore

struct CodeFileEditorView: View {
    let selection: CodePreviewSelection
    let onViewReadOnly: () -> Void
    let onClose: () -> Void

    @Environment(\.gitService) private var gitService
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var store = EditorSurfaceStore()
    @State private var phase: Phase = .loading
    @State private var baseline: FileBaseline?
    @State private var language: CodeSyntaxLanguage = .plain
    @State private var saveError: String?
    @State private var externalChange = false
    @State private var pendingExit: PendingExit?

    private enum Phase: Equatable {
        case loading
        case editing
        case ineligible(String)
        case failed(String)
    }

    private enum PendingExit: Equatable {
        case close
        case viewReadOnly
    }

    private struct FileBaseline {
        let hash: String
        let head: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: selection.id) { await load() }
        .onChange(of: store.saveRequestID) { _, _ in
            Task { await save() }
        }
        .onChange(of: colorScheme) { _, _ in
            store.setTheme(themePayload())
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await detectExternalChange() }
        }
        .onDisappear { store.tearDown() }
        .alert(
            "Save changes to \(selection.fileName)?",
            isPresented: Binding(
                get: { pendingExit != nil },
                set: { if !$0 { pendingExit = nil } }
            )
        ) {
            Button("Save") {
                let exit = pendingExit
                pendingExit = nil
                Task {
                    await performWrite()
                    if saveError == nil { perform(exit) }
                }
            }
            Button("Discard", role: .destructive) {
                let exit = pendingExit
                pendingExit = nil
                perform(exit)
            }
            Button("Cancel", role: .cancel) { pendingExit = nil }
        } message: {
            Text("This file has unsaved changes.")
        }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: selection.mode == .reviewDiff ? "plusminus" : "pencil")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(selection.fileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if store.isDirty {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unsaved changes")
                    }
                }

                Text(selection.mode == .reviewDiff ? "Reviewing changes" : "Editing")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await save() }
            } label: {
                Text("Save")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!store.isDirty || phase != .editing)
            .help("Save (Cmd+S)")

            Button {
                requestExit(.viewReadOnly)
            } label: {
                Label("View", systemImage: "eye")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Switch to read-only view")

            Button {
                requestExit(.close)
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close Editor")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading \(selection.fileName)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .editing:
            ZStack(alignment: .top) {
                EditorSurfaceView(store: store)
                if externalChange {
                    conflictBanner
                }
            }

        case .ineligible(let message):
            ContentUnavailableView {
                Label("Can't edit here", systemImage: "lock.doc")
            } description: {
                Text(message)
            } actions: {
                Button("View read-only") { onViewReadOnly() }
            }

        case .failed(let message):
            ContentUnavailableView(
                "Editor Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This file changed on disk (likely the agent). Keep your edits or reload?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Keep my changes") {
                Task { await performWrite() }
            }
            Button("Reload from disk") {
                Task { await reloadFromDisk() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
        .padding(12)
        .shadow(radius: 4, y: 2)
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        phase = .loading
        saveError = nil
        externalChange = false

        let fileURL = selection.fileURL
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            if data.contains(0) {
                phase = .ineligible("Binary files can't be edited in the app.")
                return
            }
            if data.count > CodePreviewLoader.maxPreviewBytes {
                phase = .ineligible("This file is too large to edit in the app.")
                return
            }
            let working = String(decoding: data, as: UTF8.self)
            let head = await headContent()
            language = CodeSyntaxLanguage(fileExtension: fileURL.pathExtension)
            baseline = FileBaseline(hash: Self.hash(data), head: head)
            phase = .editing
            store.load(initPayload(working: working, head: head))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func headContent() async -> String {
        let head = try? await gitService.showHead(file: selection.relativePath, at: selection.rootURL)
        return (head ?? nil) ?? ""
    }

    // MARK: - Saving

    @MainActor
    private func save() async {
        guard phase == .editing, store.isDirty else { return }
        if await fileChangedOnDisk() {
            externalChange = true
            return
        }
        await performWrite()
    }

    @MainActor
    private func performWrite() async {
        guard let content = await store.currentDocument() else {
            saveError = "Couldn't read the editor contents."
            return
        }
        do {
            try await gitService.writeFile(content, to: selection.relativePath, at: selection.rootURL)
            baseline = FileBaseline(hash: Self.hash(Data(content.utf8)), head: baseline?.head ?? "")
            store.markSaved()
            externalChange = false
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Conflict detection

    @MainActor
    private func detectExternalChange() async {
        guard phase == .editing, await fileChangedOnDisk() else { return }
        if store.isDirty {
            externalChange = true
        } else {
            await reloadFromDisk()
        }
    }

    private func fileChangedOnDisk() async -> Bool {
        guard let baseline else { return false }
        guard let data = try? Data(contentsOf: selection.fileURL, options: [.mappedIfSafe]) else {
            return false
        }
        return Self.hash(data) != baseline.hash
    }

    @MainActor
    private func reloadFromDisk() async {
        guard
            let data = try? Data(contentsOf: selection.fileURL, options: [.mappedIfSafe]),
            !data.contains(0)
        else { return }
        let working = String(decoding: data, as: UTF8.self)
        let head = await headContent()
        baseline = FileBaseline(hash: Self.hash(data), head: head)
        externalChange = false
        store.reload(initPayload(working: working, head: head))
    }

    // MARK: - Exit

    private func requestExit(_ exit: PendingExit) {
        if store.isDirty {
            pendingExit = exit
        } else {
            perform(exit)
        }
    }

    private func perform(_ exit: PendingExit?) {
        switch exit {
        case .close: onClose()
        case .viewReadOnly: onViewReadOnly()
        case .none: break
        }
    }

    // MARK: - Payloads

    private func initPayload(working: String, head: String) -> EditorInitPayload {
        EditorInitPayload(
            mode: selection.mode == .reviewDiff ? "review" : "edit",
            head: head,
            working: working,
            language: language.bridgeIdentifier,
            theme: colorScheme == .dark ? "dark" : "light",
            fontFamily: Self.monospaceFamily,
            fontSize: Self.fontSize
        )
    }

    private func themePayload() -> EditorThemePayload {
        EditorThemePayload(
            theme: colorScheme == .dark ? "dark" : "light",
            fontFamily: Self.monospaceFamily,
            fontSize: Self.fontSize
        )
    }

    private static let monospaceFamily = "ui-monospace, SFMono-Regular, Menlo, monospace"
    private static let fontSize: Double = 12

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CodeSyntaxLanguage {
    /// Token the embedded editor bundle maps to a CodeMirror language.
    fileprivate var bridgeIdentifier: String {
        switch self {
        case .swift: return "swift"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .python: return "python"
        case .json: return "json"
        case .markdown: return "markdown"
        case .shell: return "shell"
        case .plain: return "plain"
        }
    }
}
