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

    @Test("Navigation policy allows additional exact allowlisted domains")
    func navigationPolicyAllowsAdditionalExactDomains() {
        let policy = WebNavigationPolicy(
            allowedHost: "example.com",
            additionalAllowedDomains: ["portal.example.net"]
        )

        #expect(policy.shouldAllow(url: URL(string: "https://portal.example.net/docs")!))
        #expect(!policy.shouldAllow(url: URL(string: "https://www.portal.example.net/docs")!))
    }

    @Test("Navigation policy allows additional wildcard allowlisted domains")
    func navigationPolicyAllowsAdditionalWildcardDomains() {
        let policy = WebNavigationPolicy(
            allowedHost: "example.com",
            additionalAllowedDomains: ["*.swift.org"]
        )

        #expect(policy.shouldAllow(url: URL(string: "https://swift.org/documentation")!))
        #expect(policy.shouldAllow(url: URL(string: "https://docs.swift.org/documentation")!))
        #expect(!policy.shouldAllow(url: URL(string: "https://swift.com/documentation")!))
    }

    @Test("Blocked main-frame navigation opens externally and records callback")
    func blockedMainFrameNavigationOpensExternally() {
        let blockedURL = URL(string: "https://example.net/path")!
        var openedURLs: [URL] = []
        var callbackURLs: [URL] = []

        let policy = WebNavigationPolicy(
            allowedHost: "example.com",
            openURL: { openedURLs.append($0) },
            onBlockedNavigation: { callbackURLs.append($0) }
        )

        let didOpen = policy.handleBlockedNavigation(
            url: blockedURL,
            targetFrameIsMainFrame: true,
            navigationType: .linkActivated
        )

        #expect(didOpen)
        #expect(openedURLs == [blockedURL])
        #expect(callbackURLs == [blockedURL])
    }

    @Test("Blocked subframe navigation is canceled without external open")
    func blockedSubframeNavigationDoesNotOpenExternally() {
        let blockedURL = URL(string: "https://example.net/path")!
        var openedURLs: [URL] = []
        var callbackURLs: [URL] = []

        let policy = WebNavigationPolicy(
            allowedHost: "example.com",
            openURL: { openedURLs.append($0) },
            onBlockedNavigation: { callbackURLs.append($0) }
        )

        let didOpen = policy.handleBlockedNavigation(
            url: blockedURL,
            targetFrameIsMainFrame: false,
            navigationType: .linkActivated
        )

        #expect(!didOpen)
        #expect(openedURLs.isEmpty)
        #expect(callbackURLs.isEmpty)
    }

    @Test("Blocked automatic navigation does not open external browser")
    func blockedAutomaticNavigationDoesNotOpenExternally() {
        let blockedURL = URL(string: "https://example.net/path")!
        var openedURLs: [URL] = []
        var callbackURLs: [URL] = []

        let policy = WebNavigationPolicy(
            allowedHost: "example.com",
            openURL: { openedURLs.append($0) },
            onBlockedNavigation: { callbackURLs.append($0) }
        )

        let didOpen = policy.handleBlockedNavigation(
            url: blockedURL,
            targetFrameIsMainFrame: true,
            navigationType: .other
        )

        #expect(!didOpen)
        #expect(openedURLs.isEmpty)
        #expect(callbackURLs.isEmpty)
    }

    @Test("Related top-level navigation is kept in-app by adopting host")
    func relatedTopLevelNavigationAdoptsHost() {
        let policy = WebNavigationPolicy(allowedHost: "docs.swift.org")

        let didAdopt = policy.adoptAllowedHostForRelatedNavigationIfNeeded(
            candidateURL: URL(string: "https://swift.org/documentation")!,
            targetFrameIsMainFrame: true
        )

        #expect(didAdopt)
        #expect(policy.activeAllowedHost == "swift.org")
        #expect(policy.shouldAllow(url: URL(string: "https://www.swift.org/download/")!))
    }

    @Test("Unrelated top-level navigation does not adopt host")
    func unrelatedTopLevelNavigationDoesNotAdoptHost() {
        let policy = WebNavigationPolicy(allowedHost: "docs.swift.org")

        let didAdopt = policy.adoptAllowedHostForRelatedNavigationIfNeeded(
            candidateURL: URL(string: "https://example.net/")!,
            targetFrameIsMainFrame: true
        )

        #expect(!didAdopt)
        #expect(policy.activeAllowedHost == "docs.swift.org")
    }

    @Test("Host adoption does not occur for subframe navigation")
    func subframeNavigationPreventsHostAdoption() {
        let policy = WebNavigationPolicy(allowedHost: "docs.swift.org")

        let didAdopt = policy.adoptAllowedHostForRelatedNavigationIfNeeded(
            candidateURL: URL(string: "https://swift.org/documentation")!,
            targetFrameIsMainFrame: false
        )

        #expect(!didAdopt)
        #expect(policy.activeAllowedHost == "docs.swift.org")
    }

    @Test("Web surface store is lazy until first URL source selection")
    func webSurfaceStoreStartsLazy() {
        let store = WebSurfaceStore(autoLoadInitialURL: false)
        #expect(!store.hasInstantiatedSurface)
        #expect(!store.hasActiveSurface)
    }

    @Test("Web surface store creates once and reuses surface for same source")
    func webSurfaceStoreReusesForSameSource() {
        let store = WebSurfaceStore(autoLoadInitialURL: false)
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
        let store = WebSurfaceStore(autoLoadInitialURL: false)
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
        let store = WebSurfaceStore(autoLoadInitialURL: false)
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
        let store = WebSurfaceStore(autoLoadInitialURL: false)
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
