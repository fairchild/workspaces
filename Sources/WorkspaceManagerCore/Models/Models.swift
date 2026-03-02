//
//  Models.swift
//  WorkspaceManager
//
//  SwiftData models for persistence
//

import Foundation
import SwiftData
import SwiftUI  // For Color in GitStatus

@Model
public final class Repo {
    public var id: UUID
    public var name: String
    public var localPath: String  // Store as String, convert to URL when needed
    public var remoteURL: String?
    public var addedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Workspace.sourceRepo)
    public var workspaces: [Workspace] = []

    public var localURL: URL {
        URL(fileURLWithPath: localPath)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        localPath: URL,
        remoteURL: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.localPath = localPath.path
        self.remoteURL = remoteURL
        self.addedAt = addedAt
    }
}

@Model
public final class WebSource {
    public var id: UUID
    public var name: String
    public var baseURLString: String
    public var allowedHost: String
    public var addedAt: Date
    public var lastAccessedAt: Date

    public var baseURL: URL? {
        URL(string: baseURLString)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        baseURLString: String,
        allowedHost: String,
        addedAt: Date = Date(),
        lastAccessedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.allowedHost = allowedHost.lowercased()
        self.addedAt = addedAt
        self.lastAccessedAt = lastAccessedAt
    }
}

@Model
public final class Workspace {
    public var id: UUID
    public var name: String
    public var path: String  // Store as String, convert to URL when needed
    public var sourceRepo: Repo?
    public var createdAt: Date
    public var lastAccessedAt: Date
    public var statusRaw: String
    public var gitBranch: String?

    /// Isolation backend identifier ("local", "daytona", etc.)
    public var backendIdentifier: String = "local"

    /// Daytona sandbox ID for remote workspaces (nil for local)
    public var sandboxId: String?

    public var workspaceURL: URL {
        URL(fileURLWithPath: path)
    }

    public var isRemote: Bool {
        backendIdentifier == DaytonaBackend.identifier
    }

    public var status: WorkspaceStatus {
        get { WorkspaceStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        sourceRepo: Repo,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        status: WorkspaceStatus = .active,
        gitBranch: String? = nil,
        backendIdentifier: String = "local",
        sandboxId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path.path
        self.sourceRepo = sourceRepo
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.statusRaw = status.rawValue
        self.gitBranch = gitBranch
        self.backendIdentifier = backendIdentifier
        self.sandboxId = sandboxId
    }
}

public enum WorkspaceStatus: String, Codable, CaseIterable, Sendable {
    case active
    case archived

    public var label: String {
        switch self {
        case .active: return "Active"
        case .archived: return "Archived"
        }
    }
}

// MARK: - File Change (Runtime only, not persisted)

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: GitStatus

    public init(path: String, status: GitStatus) {
        self.path = path
        self.status = status
    }
}

public enum GitStatus: String, CaseIterable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case untracked = "?"
    case renamed = "R"

    public var icon: String {
        switch self {
        case .modified: return "pencil.circle.fill"
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .untracked: return .gray
        case .renamed: return .blue
        }
    }
}

// MARK: - File Node (for file tree display)

public struct FileNode: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public var children: [FileNode]?

    public init(name: String, path: String, isDirectory: Bool, children: [FileNode]? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }

    public var icon: String {
        if isDirectory {
            return "folder.fill"
        }

        // File type icons based on extension
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "py": return "doc.text"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "html", "htm": return "globe"
        case "css", "scss": return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "pdf": return "doc.fill"
        case "zip", "tar", "gz": return "doc.zipper"
        default: return "doc"
        }
    }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}
