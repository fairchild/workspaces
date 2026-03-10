import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("KeychainHelper", .serialized)
struct KeychainHelperTests {
    // Use a unique key prefix per test run to avoid polluting the real keychain
    private static let testPrefix = "test-\(UUID().uuidString.prefix(8))"

    private func testKey(_ name: String) -> String {
        "\(Self.testPrefix)-\(name)"
    }

    @Test("save and load roundtrip")
    func saveLoadRoundtrip() throws {
        let key = testKey("roundtrip")
        defer { try? KeychainHelper.delete(key: key) }

        try KeychainHelper.saveString(key: key, value: "hello-world")
        let loaded = try KeychainHelper.loadString(key: key)
        #expect(loaded == "hello-world")
    }

    @Test("load missing key returns nil")
    func loadMissing() throws {
        let key = testKey("missing")
        let result = try KeychainHelper.loadString(key: key)
        #expect(result == nil)
    }

    @Test("save overwrites existing value")
    func saveOverwrite() throws {
        let key = testKey("overwrite")
        defer { try? KeychainHelper.delete(key: key) }

        try KeychainHelper.saveString(key: key, value: "first")
        try KeychainHelper.saveString(key: key, value: "second")
        let loaded = try KeychainHelper.loadString(key: key)
        #expect(loaded == "second")
    }

    @Test("delete removes item")
    func deleteRemoves() throws {
        let key = testKey("delete")

        try KeychainHelper.saveString(key: key, value: "to-delete")
        try KeychainHelper.delete(key: key)
        let loaded = try KeychainHelper.loadString(key: key)
        #expect(loaded == nil)
    }

    @Test("delete nonexistent key does not throw")
    func deleteIdempotent() throws {
        let key = testKey("nonexistent")
        try KeychainHelper.delete(key: key)
    }

    @Test("save and load binary data")
    func binaryRoundtrip() throws {
        let key = testKey("binary")
        defer { try? KeychainHelper.delete(key: key) }

        let data = Data([0x00, 0xFF, 0x42, 0x13])
        try KeychainHelper.save(key: key, data: data)
        let loaded = try KeychainHelper.load(key: key)
        #expect(loaded == data)
    }

    @Test("KeychainError provides descriptive messages")
    func errorDescriptions() {
        let save = KeychainError.saveFailed(-25299)
        #expect(save.errorDescription?.contains("-25299") == true)

        let load = KeychainError.loadFailed(-25300)
        #expect(load.errorDescription?.contains("load") == true)

        let unexpected = KeychainError.unexpectedData
        #expect(unexpected.errorDescription?.contains("unexpected") == true)
    }
}
