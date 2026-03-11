import Foundation
import SwiftData
import WorkspaceManagerCore

@MainActor
struct LaunchRepositoryService {
    let modelContext: ModelContext

    func trackedRepo(matchingNormalizedPath normalizedPath: String) -> Repo? {
        let descriptor = FetchDescriptor<Repo>()
        guard let fetchedRepos = try? modelContext.fetch(descriptor) else {
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
