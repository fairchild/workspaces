import AppKit
import SwiftUI

struct WorkspaceEditorToolbarButton: View {
    let workspaceName: String
    let editorOptions: [ExternalEditorDescriptor]
    let defaultEditor: ExternalEditorDescriptor
    let onOpenInDefaultEditor: () -> Void
    let onOpenInEditor: (ExternalEditorID) -> Void
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void

    var body: some View {
        ControlGroup {
            Button {
                onOpenInDefaultEditor()
            } label: {
                HStack(spacing: 4) {
                    Text(defaultEditor.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text("/\(workspaceName)")
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                }
                .frame(minWidth: 60)
            }
            .help("Open in \(defaultEditor.displayName)")

            Menu {
                ForEach(editorOptions) { editor in
                    Button(editor.displayName) {
                        onOpenInEditor(editor.id)
                    }
                }

                Divider()

                Button("Reveal in Finder") {
                    onRevealInFinder()
                }

                Button("Copy Path") {
                    onCopyPath()
                }
            } label: {
                HStack(spacing: 2) {
                    Text("Open")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Choose editor or action")
            .help("Choose editor or action")
        }
        .controlGroupStyle(.navigation)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Open \(workspaceName) in \(defaultEditor.displayName)")
    }
}
