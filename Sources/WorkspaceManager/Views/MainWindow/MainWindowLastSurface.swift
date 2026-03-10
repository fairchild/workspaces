import Foundation
import WorkspaceManagerCore

struct MainWindowLastSurface: Codable, Equatable {
    enum Kind: String, Codable {
        case repoOverview
        case repoTerminal
        case workspaceTerminal
        case webView
    }

    static let storageKey = "mainWindow.lastSurface"

    let kind: Kind
    let id: UUID

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(from rawValue: String) -> MainWindowLastSurface? {
        guard !rawValue.isEmpty else { return nil }
        guard let data = rawValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MainWindowLastSurface.self, from: data)
    }
}

enum MainWindowLaunchSurface {
    case repoOverview(Repo)
    case repoTerminal(Repo)
    case workspace(Workspace)
    case webView(WebSource)
}
