import AppKit
import SwiftUI

struct AppBuildIdentityBadge: View {
    let identity: AppBuildIdentity

    var body: some View {
        if identity.isDevelopment {
            HStack(spacing: 7) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)

                Text("DEV")
                    .font(.system(size: 10, weight: .black, design: .rounded))

                if let displayPath = identity.displayPath {
                    Text(displayPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accentColor.opacity(0.14), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(accentColor.opacity(0.4), lineWidth: 1)
            )
            .help(helpText)
            .contextMenu {
                Button("Copy Build Path") {
                    copyToPasteboard(identity.fullPath)
                }

                if identity.launchPath != identity.fullPath {
                    Button("Copy Launch Path") {
                        copyToPasteboard(identity.launchPath)
                    }
                }
            }
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accentColor: Color {
        Color(hue: identity.hueDegrees / 360.0, saturation: 0.62, brightness: 0.82)
    }

    private var accessibilityLabel: String {
        if let displayPath = identity.displayPath {
            return "Development build from \(displayPath)"
        }

        return "Development build"
    }

    private var helpText: String {
        if identity.launchPath == identity.fullPath {
            return "Development build\nPath: \(identity.fullPath)"
        }

        return """
            Development build
            Path: \(identity.fullPath)
            Launch: \(identity.launchPath)
            """
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
