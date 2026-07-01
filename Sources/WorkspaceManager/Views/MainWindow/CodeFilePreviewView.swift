//
//  CodeFilePreviewView.swift
//  WorkspaceManager
//
//  Guarded source preview/editor for small local text files.
//

import AppKit
import SwiftUI

struct CodePreviewSelection: Identifiable, Hashable {
    let rootURL: URL
    let relativePath: String

    var id: String {
        "\(rootURL.path)#\(relativePath)"
    }

    var fileURL: URL {
        rootURL.appendingPathComponent(relativePath)
    }

    var fileName: String {
        fileURL.lastPathComponent
    }
}

struct CodeFilePreviewView: View {
    let selection: CodePreviewSelection
    let editorOptions: [ExternalEditorDescriptor]
    let defaultEditor: ExternalEditorDescriptor?
    let onOpenInDefaultEditor: () -> Void
    let onOpenInEditor: (ExternalEditorID) -> Void
    let onSaved: () -> Void
    let onClose: () -> Void

    @State private var state: LoadState = .loading
    @State private var isSaving = false
    @State private var saveStatusMessage: String?
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.fileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(selection.relativePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let document = loadedDocument {
                    if document.isDirty {
                        Text("Unsaved")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text(document.language.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if document.isReadOnly {
                        Text(document.readOnlyBadgeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let saveStatusMessage {
                        Text(saveStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    }
                }

                if isEditorLoaded {
                    Button {
                        discardChanges()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isDirty)
                    .help("Discard in-memory edits")
                    .accessibilityLabel("Discard Edits")

                    Button {
                        saveDocument()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canSave)
                    .help(canSave ? "Save file" : "Save is available for dirty, safely loaded text files")
                    .accessibilityLabel("Save File")
                }

                if let defaultEditor {
                    OpenInEditorSplitButton(
                        editorOptions: editorOptions,
                        defaultEditor: defaultEditor,
                        onOpenInDefaultEditor: onOpenInDefaultEditor,
                        onOpenInEditor: onOpenInEditor
                    )
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Close Preview")
                .accessibilityLabel("Close Preview")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch state {
                case .loading:
                    ProgressView("Loading \(selection.fileName)...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )

                case .loaded(let document):
                    VStack(spacing: 0) {
                        if let saveErrorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text(saveErrorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor))

                            Divider()
                        }

                        if document.canEdit {
                            EditableCodeTextView(text: currentTextBinding)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            readOnlyDocumentView(document)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: selection.id) {
            await loadPreview()
        }
    }

    @ViewBuilder
    private func readOnlyDocumentView(_ document: CodeEditorDocument) -> some View {
        VStack(spacing: 0) {
            if let reason = document.readOnlyReason {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()
            }

            ReadOnlyCodeTextView(attributedText: document.attributedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    private func loadPreview() async {
        state = .loading
        saveStatusMessage = nil
        saveErrorMessage = nil
        CodePreviewDiagnostics.log("selected file=\(selection.fileURL.path)")

        do {
            let payload = try await CodePreviewLoader.load(fileURL: selection.fileURL)
            if Task.isCancelled {
                CodePreviewDiagnostics.log("load cancelled file=\(selection.fileURL.path)")
                return
            }

            CodePreviewDiagnostics.log(
                "payload loaded file=\(selection.fileURL.path) chars=\(payload.text.count) truncated=\(payload.isTruncated)"
            )

            state = .loaded(CodeEditorDocument(payload: payload))
            CodePreviewDiagnostics.log("state=loaded file=\(selection.fileURL.path)")
        } catch is CancellationError {
            CodePreviewDiagnostics.log("state=cancelled file=\(selection.fileURL.path)")
            return
        } catch let error as CodePreviewError {
            state = .failed(error.errorDescription ?? "Could not load this file.")
            CodePreviewDiagnostics.log(
                "state=failed file=\(selection.fileURL.path) error=\(error.errorDescription ?? "unknown")"
            )
        } catch {
            state = .failed(error.localizedDescription)
            CodePreviewDiagnostics.log(
                "state=failed file=\(selection.fileURL.path) error=\(error.localizedDescription)"
            )
        }
    }

    private var loadedDocument: CodeEditorDocument? {
        guard case .loaded(let document) = state else { return nil }
        return document
    }

    private var isEditorLoaded: Bool {
        loadedDocument != nil
    }

    private var isDirty: Bool {
        loadedDocument?.isDirty ?? false
    }

    private var canSave: Bool {
        guard let document = loadedDocument else { return false }
        return document.canSave && !isSaving
    }

    private var currentTextBinding: Binding<String> {
        Binding(
            get: {
                loadedDocument?.currentText ?? ""
            },
            set: { newValue in
                guard case .loaded(var document) = state else { return }
                document.currentText = newValue
                state = .loaded(document)
            }
        )
    }

    private func discardChanges() {
        guard case .loaded(var document) = state else { return }
        document.currentText = document.originalText
        state = .loaded(document)
        saveErrorMessage = nil
        saveStatusMessage = nil
    }

    private func saveDocument() {
        guard case .loaded(let document) = state, document.canSave else { return }

        isSaving = true
        saveErrorMessage = nil
        saveStatusMessage = nil

        Task {
            do {
                let snapshot = try await CodeEditorSaveService.save(
                    CodeEditorSaveRequest(
                        rootURL: selection.rootURL,
                        relativePath: selection.relativePath,
                        editedText: document.currentText,
                        snapshot: document.fileSnapshot
                    )
                )
                await MainActor.run {
                    guard case .loaded(var latestDocument) = state else { return }
                    latestDocument.markSaved(snapshot: snapshot)
                    state = .loaded(latestDocument)
                    isSaving = false
                    saveStatusMessage = "Saved"
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

enum CodeEditorEditability: Equatable {
    case editable
    case readOnly(String)
}

struct CodeEditorDocument: Equatable {
    var originalText: String
    var currentText: String
    let language: CodeSyntaxLanguage
    let spans: [HighlightSpan]
    let editability: CodeEditorEditability
    var fileSnapshot: CodeEditorFileSnapshot?

    init(payload: CodePreviewPayload) {
        originalText = payload.text
        currentText = payload.text
        language = payload.language
        spans = payload.spans
        editability = Self.editability(for: payload)
        fileSnapshot = payload.fileSnapshot
    }

    var canEdit: Bool {
        editability == .editable
    }

    var isReadOnly: Bool {
        !canEdit
    }

    var isDirty: Bool {
        currentText != originalText
    }

    var canSave: Bool {
        canEdit && isDirty && fileSnapshot != nil
    }

    var readOnlyReason: String? {
        guard case .readOnly(let reason) = editability else { return nil }
        return reason
    }

    var readOnlyBadgeText: String {
        if case .readOnly = editability {
            return "Read Only"
        }
        return ""
    }

    var attributedText: NSAttributedString {
        CodeSyntaxHighlighter.makeAttributedText(
            from: CodePreviewPayload(
                text: currentText,
                language: language,
                spans: spans,
                isTruncated: isReadOnly
            )
        )
    }

    mutating func markSaved(snapshot: CodeEditorFileSnapshot) {
        originalText = currentText
        fileSnapshot = snapshot
    }

    private static func editability(for payload: CodePreviewPayload) -> CodeEditorEditability {
        if let readOnlyReason = payload.readOnlyReason {
            return .readOnly(readOnlyReason)
        }
        if payload.isTruncated {
            return .readOnly(
                "This file is too large for in-app editing. The preview is truncated; open externally to edit safely."
            )
        }
        return .editable
    }
}

private struct OpenInEditorSplitButton: View {
    let editorOptions: [ExternalEditorDescriptor]
    let defaultEditor: ExternalEditorDescriptor
    let onOpenInDefaultEditor: () -> Void
    let onOpenInEditor: (ExternalEditorID) -> Void

    @State private var isHoveringPrimarySegment = false
    @State private var isHoveringMenuSegment = false

    private var alternateEditorOptions: [ExternalEditorDescriptor] {
        editorOptions.filter { $0.id != defaultEditor.id }
    }

    private var hasAlternateEditorOptions: Bool {
        !alternateEditorOptions.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onOpenInDefaultEditor()
            } label: {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 52, minHeight: OpenControlMetrics.height, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(
                OpenControlSegmentButtonStyle(
                    isHovered: isHoveringPrimarySegment,
                    isDisabled: false
                )
            )
            .onHover { isHoveringPrimarySegment = $0 }

            Rectangle()
                .fill(OpenControlPalette.border)
                .frame(width: OpenControlMetrics.dividerWidth)
                .padding(.vertical, 4)
                .opacity(hasAlternateEditorOptions ? 1 : 0.45)

            Menu {
                Button("Open in...") {
                    onOpenInDefaultEditor()
                }
                .keyboardShortcut(
                    AppChromeShortcut.openInEditor.keyEquivalent,
                    modifiers: AppChromeShortcut.openInEditor.eventModifiers
                )

                if hasAlternateEditorOptions {
                    Divider()

                    ForEach(alternateEditorOptions) { editor in
                        Button(editor.displayName) {
                            onOpenInEditor(editor.id)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(
                        width: OpenControlMetrics.chevronSegmentWidth,
                        height: OpenControlMetrics.height,
                        alignment: .center
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(
                OpenControlSegmentButtonStyle(
                    isHovered: isHoveringMenuSegment,
                    isDisabled: !hasAlternateEditorOptions
                )
            )
            .onHover { isHoveringMenuSegment = $0 }
            .menuIndicator(.hidden)
            .disabled(!hasAlternateEditorOptions)
            .accessibilityLabel("Choose editor")
            .help(hasAlternateEditorOptions ? "Choose editor" : "No alternate editors available")
        }
        .frame(height: OpenControlMetrics.height)
        .background(OpenControlPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: OpenControlMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OpenControlMetrics.cornerRadius, style: .continuous)
                .stroke(OpenControlPalette.border, lineWidth: OpenControlMetrics.borderWidth)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("Open in \(defaultEditor.displayName) (Cmd+Shift+O)")
        .accessibilityLabel("Open in \(defaultEditor.displayName)")
    }
}

private enum OpenControlMetrics {
    static let height: CGFloat = 24
    static let chevronSegmentWidth: CGFloat = 24
    static let dividerWidth: CGFloat = 1
    static let borderWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 6
}

private enum OpenControlPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.9)
    static let hover = Color.primary.opacity(0.08)
    static let pressed = Color.primary.opacity(0.14)
}

private struct OpenControlSegmentButtonStyle: ButtonStyle {
    let isHovered: Bool
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
            .background(
                Group {
                    if isDisabled {
                        Color.clear
                    } else if configuration.isPressed {
                        OpenControlPalette.pressed
                    } else if isHovered {
                        OpenControlPalette.hover
                    } else {
                        Color.clear
                    }
                }
            )
    }
}

private struct ReadOnlyCodeTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PreviewTextContainerView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.textContainerInset = NSSize(width: 12, height: 10)

        let containerView = PreviewTextContainerView(textView: textView)
        context.coordinator.textView = textView
        context.coordinator.apply(text: attributedText)
        return containerView
    }

    func updateNSView(_ nsView: PreviewTextContainerView, context: Context) {
        _ = nsView
        context.coordinator.apply(text: attributedText)
    }

    final class PreviewTextContainerView: NSView {
        let scrollView: NSScrollView
        let textView: NSTextView

        init(textView: NSTextView) {
            self.textView = textView
            self.scrollView = NSScrollView(frame: .zero)
            super.init(frame: .zero)

            scrollView.frame = bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.documentView = textView

            addSubview(scrollView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        private var lastAppliedText: String?
        private var applyCount = 0

        func apply(text: NSAttributedString) {
            guard let textView else { return }

            if lastAppliedText == text.string {
                return
            }
            lastAppliedText = text.string
            applyCount += 1
            CodePreviewDiagnostics.log("render apply count=\(applyCount) chars=\(text.length)")

            textView.textStorage?.setAttributedString(text)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
}

private struct EditableCodeTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> EditableTextContainerView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = context.coordinator

        let containerView = EditableTextContainerView(textView: textView)
        context.coordinator.textView = textView
        context.coordinator.apply(text: text)
        return containerView
    }

    func updateNSView(_ nsView: EditableTextContainerView, context: Context) {
        _ = nsView
        context.coordinator.text = $text
        context.coordinator.apply(text: text)
    }

    final class EditableTextContainerView: NSView {
        let scrollView: NSScrollView
        let textView: NSTextView

        init(textView: NSTextView) {
            self.textView = textView
            self.scrollView = NSScrollView(frame: .zero)
            super.init(frame: .zero)

            scrollView.frame = bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.documentView = textView

            addSubview(scrollView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        var text: Binding<String>
        private var isApplyingProgrammaticText = false

        init(text: Binding<String>) {
            self.text = text
        }

        func apply(text newText: String) {
            guard let textView, textView.string != newText else { return }

            isApplyingProgrammaticText = true
            let selectedRange = textView.selectedRange()
            textView.string = newText
            let boundedLocation = min(selectedRange.location, (newText as NSString).length)
            textView.setSelectedRange(NSRange(location: boundedLocation, length: 0))
            isApplyingProgrammaticText = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticText, let textView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private enum LoadState {
    case loading
    case loaded(CodeEditorDocument)
    case failed(String)
}
