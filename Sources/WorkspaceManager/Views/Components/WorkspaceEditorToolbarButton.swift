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
                Label {
                    Text("Open in \(defaultEditor.displayName)")
                        .font(.system(size: 12, weight: .medium))
                } icon: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11, weight: .semibold))
                }
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
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
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
