import Foundation
import Testing

@testable import WorkspaceManager

/// Regression coverage for the `Bundle.module` lookup that locates the bundled
/// `event-forwarder.sh` and `title-emit.sh` shell scripts. A previous iteration
/// of `extractHookForwarderScript` read from `Bundle.main`, which silently
/// failed for `swift build` debug binaries because SPM stores target resources
/// in `WorkspaceManager_WorkspaceManager.bundle` (i.e. `Bundle.module`), not in
/// the executable's main bundle. The lifecycle then logged
/// "event-forwarder.sh extraction failed" and skipped Channel 1 entirely, which
/// silently disables real Claude Code hooks for every developer running locally.
@Suite("ClaudeIntegrationLifecycle resource extraction")
struct ClaudeIntegrationLifecycleResourceTests {
    @Test("event-forwarder.sh extracts from the bundle and is executable")
    func eventForwarderExtracts() throws {
        let path = try #require(ClaudeIntegrationLifecycle.extractEventForwarderScript())

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.hasPrefix("#!"))
    }

    @Test("title-emit.sh extracts from the bundle and is executable")
    func titleEmitExtracts() throws {
        let path = try #require(ClaudeIntegrationLifecycle.extractTitleEmitScript())

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test("statusline.sh resolves via bundled forwarder lookup")
    func statusLineForwarderResolves() throws {
        let path = try #require(ClaudeIntegrationLifecycle.bundledStatusLineForwarderPath())

        #expect(FileManager.default.fileExists(atPath: path))
    }
}
