//
//  MainWindowRenderCacheTests.swift
//  WorkspaceManagerAppTests
//
//  Behavior of the render-path memoizations (#1347 B1/B2): cached path
//  normalization stays consistent with the canonical resolver, the repo index
//  tracks repo-set changes, and the sidebar sort order tracks its inputs.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowRenderCaches")
struct MainWindowRenderCacheTests {

    @Test("Cached normalization matches the canonical resolver on repeat calls")
    func normalizeMatchesCanonical() {
        let cache = PathNormalizationCache()
        let raw = "/tmp/../tmp/render-cache-\(UUID().uuidString.prefix(6))"
        let canonical = MainWindowPathResolution.normalize(raw)
        #expect(cache.normalize(raw) == canonical)
        #expect(cache.normalize(raw) == canonical)
    }

    @Test("Repo index maps normalized paths, first repo wins on collision")
    func repoIndexFirstWins() {
        let cache = PathNormalizationCache()
        let first = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/shared"))
        let duplicate = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/shared"))

        let index = cache.repoIndex(repos: [first, duplicate])
        #expect(index.count == 1)
        #expect(index[MainWindowPathResolution.normalize("/tmp/shared")]?.id == first.id)
    }

    @Test("Repo index follows repo-set changes")
    func repoIndexFollowsChanges() {
        let cache = PathNormalizationCache()
        let alpha = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/rc-alpha"))
        let beta = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/rc-beta"))

        let initial = cache.repoIndex(repos: [alpha])
        #expect(initial.count == 1)

        let grown = cache.repoIndex(repos: [alpha, beta])
        #expect(grown.count == 2)
        #expect(grown[MainWindowPathResolution.normalize("/tmp/rc-beta")]?.id == beta.id)

        let shrunk = cache.repoIndex(repos: [beta])
        #expect(shrunk.count == 1)
        #expect(shrunk[MainWindowPathResolution.normalize("/tmp/rc-alpha")] == nil)
    }

    @Test("Repo index rebuilds when duplicate-path repos swap order")
    func repoIndexDuplicatePathReorder() {
        let cache = PathNormalizationCache()
        let first = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/dup-shared"))
        let second = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/dup-shared"))
        let key = MainWindowPathResolution.normalize("/tmp/dup-shared")

        #expect(cache.repoIndex(repos: [first, second])[key]?.id == first.id)
        // Same path fingerprint, different first-wins winner: must rebuild.
        #expect(cache.repoIndex(repos: [second, first])[key]?.id == second.id)
    }

    @Test("Repo index rebuilds when an instance is replaced at the same path")
    func repoIndexInstanceReplacement() {
        let cache = PathNormalizationCache()
        let original = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/repl-shared"))
        let key = MainWindowPathResolution.normalize("/tmp/repl-shared")
        #expect(cache.repoIndex(repos: [original])[key] === original)

        let replacement = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/repl-shared"))
        #expect(cache.repoIndex(repos: [replacement])[key] === replacement)
    }

    @Test("Sort cache rebuilds when an instance is replaced with identical fields")
    func sortCacheInstanceReplacement() {
        let cache = SidebarRepoSortCache()
        let controller = SidebarRepoSortController()
        let original = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/sr-a"))

        let initial = cache.sortedRepos(
            [original], mode: .alphabetical, lastAccessedSnapshot: [:], controller: controller)
        #expect(initial.first === original)

        let replacement = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/sr-a"))
        let replaced = cache.sortedRepos(
            [replacement], mode: .alphabetical, lastAccessedSnapshot: [:], controller: controller)
        #expect(replaced.first === replacement)
    }

    @Test("Sidebar sort cache tracks renames and mode flips")
    func sortCacheTracksInputs() {
        let cache = SidebarRepoSortCache()
        let controller = SidebarRepoSortController()
        let alpha = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/sc-a"))
        let zulu = Repo(name: "zulu", localPath: URL(fileURLWithPath: "/tmp/sc-z"))
        let repos = [zulu, alpha]

        let alphabetical = cache.sortedRepos(
            repos, mode: .alphabetical, lastAccessedSnapshot: [:], controller: controller)
        #expect(alphabetical.map(\.name) == ["alpha", "zulu"])

        // Same inputs: cached order (content equality is the observable contract).
        let repeated = cache.sortedRepos(
            repos, mode: .alphabetical, lastAccessedSnapshot: [:], controller: controller)
        #expect(repeated.map(\.name) == ["alpha", "zulu"])

        // A rename must invalidate the cached order.
        alpha.name = "zzz-renamed"
        let renamed = cache.sortedRepos(
            repos, mode: .alphabetical, lastAccessedSnapshot: [:], controller: controller)
        #expect(renamed.map(\.name) == ["zulu", "zzz-renamed"])

        // A mode flip re-sorts using the snapshot.
        let snapshot = [alpha.id: Date(timeIntervalSince1970: 2_000), zulu.id: Date(timeIntervalSince1970: 1_000)]
        let byAccess = cache.sortedRepos(
            repos, mode: .lastAccessed, lastAccessedSnapshot: snapshot, controller: controller)
        #expect(byAccess.first?.id == alpha.id)
    }
}
