import Foundation
import SwiftUI  // For Color in display properties

public struct WebhookEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let action: String
    public let summary: String
    public let repo: String
    public let timestamp: Date

    public init(id: String, type: String, action: String, summary: String, repo: String, timestamp: Date) {
        self.id = id
        self.type = type
        self.action = action
        self.summary = summary
        self.repo = repo
        self.timestamp = timestamp
    }

    public var icon: String {
        switch type {
        case "pull_request": return "arrow.triangle.pull"
        case "check_run": return "checkmark.circle"
        case "check_suite": return "checkmark.seal"
        case "discussion": return "bubble.left.and.bubble.right"
        case "discussion_comment": return "text.bubble"
        default: return "bell"
        }
    }

    public var color: Color {
        switch type {
        case "pull_request": return .purple
        case "check_run", "check_suite": return .green
        case "discussion", "discussion_comment": return .blue
        default: return .secondary
        }
    }
}
