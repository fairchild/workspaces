//
//  CodeFilePreviewView.swift
//  WorkspaceManager
//
//  Read-only source preview with lightweight syntax highlighting.
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
    let onClose: () -> Void

    @State private var state: LoadState = .loading

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)

                Text(selection.relativePath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let metadata = stateMetadata {
                    Text(metadata.language.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    if metadata.isTruncated {
                        Text("Preview truncated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
            .background(Color(nsColor: .controlBackgroundColor))

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
                    ReadOnlyCodeTextView(attributedText: document.attributedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .empty:
                    ContentUnavailableView(
                        "Empty File",
                        systemImage: "doc.text",
                        description: Text("This file has no content.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: selection.id) {
            await loadPreview()
        }
    }

    @MainActor
    private func loadPreview() async {
        state = .loading
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

            if payload.text.isEmpty {
                state = .empty(
                    language: payload.language,
                    isTruncated: payload.isTruncated
                )
                CodePreviewDiagnostics.log("state=empty file=\(selection.fileURL.path)")
                return
            }

            let attributedText = CodeSyntaxHighlighter.makeAttributedText(from: payload)
            state = .loaded(
                CodePreviewDocument(
                    attributedText: attributedText,
                    language: payload.language,
                    isTruncated: payload.isTruncated
                )
            )
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

    private var stateMetadata: (language: CodeSyntaxLanguage, isTruncated: Bool)? {
        switch state {
        case .loaded(let document):
            return (language: document.language, isTruncated: document.isTruncated)
        case .empty(let language, let isTruncated):
            return (language: language, isTruncated: isTruncated)
        case .loading, .failed:
            return nil
        }
    }
}

private struct OpenInEditorSplitButton: View {
    let editorOptions: [ExternalEditorDescriptor]
    let defaultEditor: ExternalEditorDescriptor
    let onOpenInDefaultEditor: () -> Void
    let onOpenInEditor: (ExternalEditorID) -> Void

    var body: some View {
        ControlGroup {
            Button("Open") {
                onOpenInDefaultEditor()
            }

            Menu {
                Button("Open in...") {
                    onOpenInDefaultEditor()
                }
                .keyboardShortcut(
                    AppChromeShortcut.openInEditor.keyEquivalent,
                    modifiers: AppChromeShortcut.openInEditor.eventModifiers
                )

                Divider()

                ForEach(editorOptions) { editor in
                    Button(editor.displayName) {
                        onOpenInEditor(editor.id)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuIndicator(.hidden)
            .frame(width: 18)
            .accessibilityLabel("Choose editor")
            .help("Choose editor")
        }
        .controlGroupStyle(.navigation)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .help("Open in \(defaultEditor.displayName) (Cmd+Shift+O)")
        .accessibilityLabel("Open in \(defaultEditor.displayName)")
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

private enum LoadState {
    case loading
    case loaded(CodePreviewDocument)
    case empty(language: CodeSyntaxLanguage, isTruncated: Bool)
    case failed(String)
}

private struct CodePreviewDocument {
    let attributedText: NSAttributedString
    let language: CodeSyntaxLanguage
    let isTruncated: Bool
}
