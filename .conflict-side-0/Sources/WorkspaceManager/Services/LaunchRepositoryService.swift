import Foundation
import OSLog
import SwiftData
import WorkspaceManagerCore

@MainActor
struct LaunchRepositoryService {
    private static let log = Logger(
        subsystem: "com.cloudcompute.workspaces",
        category: "LaunchRepositoryService"
    )

    let modelContext: ModelContext

    func trackedRepo(matchingNormalizedPath normalizedPath: String) -> Repo? {
        let descriptor = FetchDescriptor<Repo>()
        guard let fetchedRepos = try? modelContext.fetch(descriptor) else {
            Self.log.error("Failed to fetch tracked repos while resolving path \(normalizedPath, privacy: .public)")
            return nil
        }

        return fetchedRepos.first { normalizePath($0.localURL) == normalizedPath }
    }

    func existingOrImportedRepo(at repoRootPath: String) -> Repo? {
        let repoURL = URL(fileURLWithPath: repoRootPath, isDirectory: true)
        let normalizedPath = normalizePath(repoURL)

        if let existing = trackedRepo(matchingNormalizedPath: normalizedPath) {
            return existing
        }

        guard isGitRepository(at: repoURL) else {
            return nil
        }

        let repo = Repo(name: repoURL.lastPathComponent, localPath: repoURL)
        modelContext.insert(repo)

        do {
            try modelContext.save()
            return repo
        } catch {
            modelContext.rollback()
            Self.log.error(
                "Failed to save imported repo at \(repoRootPath, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private func isGitRepository(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    private func normalizePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
