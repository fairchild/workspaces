//
//  WebSourceBehaviorTests.swift
//  WorkspaceManagerAppTests
//
//  Behavior-oriented tests for URL source web policy and surface lifecycle.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("WebSourceBehavior", .serialized)
struct WebSourceBehaviorTests {
    @Test("Navigation policy allows same host and subdomains")
    func navigationPolicyAllowsHostAndSubdomains() {
        let policy = WebNavigationPolicy(allowedHost: "example.com")

        #expect(policy.shouldAllow(url: URL(string: "https://example.com")!))
        #expect(policy.shouldAllow(url: URL(string: "https://docs.example.com/path")!))
    }

    @Test("Navigation policy blocks other domains and unsupported schemes")
    func navigationPolicyBlocksOutsideDomainAndSchemes() {
        let policy = WebNavigationPolicy(allowedHost: "example.com")

        #expect(!policy.shouldAllow(url: URL(string: "https://example.net")!))
        #expect(!policy.shouldAllow(url: URL(string: "ftp://example.com")!))
        #expect(!policy.shouldAllow(url: URL(string: "file:///tmp/index.html")!))
    }

    @Test("Navigation policy can enforce exact host-only mode")
    func navigationPolicyCanDisableSubdomains() {
        let policy = WebNavigationPolicy(
            allowedHost: "example.com",
            allowsSubdomains: false
        )

        #expect(policy.shouldAllow(url: URL(string: "https://example.com")!))
        #expect(!policy.shouldAllow(url: URL(string: "https://docs.example.com")!))
    }

    @Test("Navigation policy allows about scheme for webview internals")
    func navigationPolicyAllowsAboutScheme() {
        let policy = WebNavigationPolicy(allowedHost: "example.com")
        #expect(policy.shouldAllow(url: URL(string: "about:blank")!))
    }

    @Test("Web surface store is lazy until first URL source selection")
    func webSurfaceStoreStartsLazy() {
        let store = WebSurfaceStore()
        #expect(!store.hasInstantiatedSurface)
        #expect(!store.hasActiveSurface)
    }

    @Test("Web surface store creates once and reuses surface for same source")
    func webSurfaceStoreReusesForSameSource() {
        let store = WebSurfaceStore()
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )

        let first = store.ensureSurface(for: source)
        let second = store.ensureSurface(for: source)

        #expect(store.hasInstantiatedSurface)
        #expect(store.hasActiveSurface)
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
    }

    @Test("Web surface store reuses single webview across source switches and updates policy host")
    func webSurfaceStoreSwitchesSourceWithSingleSurface() {
        let store = WebSurfaceStore()
        let firstSource = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )
        let secondSource = WebSource(
            name: "Portal",
            baseURLString: "https://portal.example.com/",
            allowedHost: "portal.example.com"
        )

        let firstView = store.ensureSurface(for: firstSource)
        let secondView = store.ensureSurface(for: secondSource)

        #expect(ObjectIdentifier(firstView) == ObjectIdentifier(secondView))
        let activePolicy = secondView.navigationDelegate as? WebNavigationPolicy
        #expect(activePolicy?.allowedHost == "portal.example.com")
    }

    @Test("Web surface release tears down active surface and allows recreation")
    func webSurfaceReleaseAndRecreate() {
        let store = WebSurfaceStore()
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )

        let first = store.ensureSurface(for: source)
        #expect(store.hasActiveSurface)

        store.releaseInactiveSurface()
        #expect(!store.hasActiveSurface)

        let second = store.ensureSurface(for: source)
        #expect(store.hasActiveSurface)
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
    }

    @Test("Scheduled release removes inactive surface")
    func scheduledReleaseRemovesSurface() async throws {
        let store = WebSurfaceStore()
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )

        _ = store.ensureSurface(for: source)
        #expect(store.hasActiveSurface)

        store.scheduleInactiveRelease(after: 0)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!store.hasActiveSurface)
    }
}
