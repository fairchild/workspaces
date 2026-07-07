import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("WebSurfaceEnumerator")
struct WebSurfaceEnumeratorTests {
    private func record(
        _ id: UUID,
        name: String,
        scope: AutomationWebSurfaceScope,
        ownerID: UUID?
    ) -> WebSurfaceRecord {
        WebSurfaceRecord(
            sourceID: id,
            displayName: name,
            configuredURL: "https://example.test/\(name)",
            scope: scope,
            ownerID: ownerID
        )
    }

    @Test("A source with no live surface lists inactive with no fabricated URL or title")
    func inactiveSourceFailsClosed() {
        let id = UUID()
        let descriptors = WebSurfaceEnumerator.descriptors(
            records: [record(id, name: "docs", scope: .global, ownerID: nil)],
            liveState: { _ in nil }
        )

        let descriptor = try! #require(descriptors.first)
        #expect(descriptor.sourceID == id)
        #expect(descriptor.scope == .global)
        #expect(descriptor.configuredURL == "https://example.test/docs")
        #expect(descriptor.isLive == false)
        #expect(descriptor.liveURL == nil)
        #expect(descriptor.title == nil)
        #expect(descriptor.isLoading == nil)
    }

    @Test("A source with a live surface reports its live URL, title, and loading state")
    func liveSourceReportsLiveState() {
        let liveID = UUID()
        let repoOwner = UUID()
        let descriptors = WebSurfaceEnumerator.descriptors(
            records: [record(liveID, name: "app", scope: .repo, ownerID: repoOwner)],
            liveState: { id in
                id == liveID
                    ? WebSurfaceLiveState(url: "https://example.test/app/home", title: "Home", isLoading: true)
                    : nil
            }
        )

        let descriptor = try! #require(descriptors.first)
        #expect(descriptor.scope == .repo)
        #expect(descriptor.ownerID == repoOwner)
        #expect(descriptor.isLive)
        #expect(descriptor.liveURL == "https://example.test/app/home")
        #expect(descriptor.title == "Home")
        #expect(descriptor.isLoading == true)
    }

    @Test("Enumeration preserves order and maps each record independently")
    func enumerationPreservesOrder() {
        let liveID = UUID()
        let inactiveID = UUID()
        let descriptors = WebSurfaceEnumerator.descriptors(
            records: [
                record(liveID, name: "live", scope: .workspace, ownerID: UUID()),
                record(inactiveID, name: "cold", scope: .global, ownerID: nil),
            ],
            liveState: { id in
                id == liveID ? WebSurfaceLiveState(url: "https://example.test/live", title: "L", isLoading: false) : nil
            }
        )

        #expect(descriptors.map(\.sourceID) == [liveID, inactiveID])
        #expect(descriptors[0].isLive)
        #expect(descriptors[1].isLive == false)
    }
}
