import SwiftUI
import WorkspaceManagerCore

extension AgentChromeProjection.Tone {
    var color: Color {
        switch self {
        case .hidden:
            return .clear
        case .live:
            return Color.accentColor.opacity(0.75)
        case .active:
            return .accentColor
        case .neutral:
            return .secondary
        case .running:
            return .blue
        case .attention:
            return .yellow
        case .critical:
            return .red
        }
    }
}
