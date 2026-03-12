import Foundation
import Security
import Testing

@testable import WorkspaceManagerCore

private enum KeychainTestSupport {
    static let disableMutatingTests = probeLegacyKeychainInteractionLockout()

    private static func probeLegacyKeychainInteractionLockout() -> Bool {
        let probeKey = "keychain-test-probe-\(UUID().uuidString)"
        let originalUseDataProtection = KeychainHelper.useDataProtection

        KeychainHelper.useDataProtection = false
        KeychainHelper.resetDataProtectionSupportCache()
        defer {
            try? KeychainHelper.delete(key: probeKey)
            KeychainHelper.useDataProtection = originalUseDataProtection
            KeychainHelper.resetDataProtectionSupportCache()
        }

        do {
            try KeychainHelper.saveString(key: probeKey, value: "probe")
            return false
        } catch KeychainError.saveFailed(let status) where status == errSecInteractionNotAllowed {
            return true
        } catch {
            return false
        }
    }
}

@Suite("KeychainHelper", .serialized)
struct KeychainHelperTests {
    // Use a unique key prefix per test run to avoid polluting the real keychain
    private static let testPrefix = "test-\(UUID().uuidString.prefix(8))"

    init() {
        // SPM test runner lacks keychain-access-groups entitlements required
        // for the data protection keychain; fall back to legacy keychain.
        KeychainHelper.useDataProtection = false
        KeychainHelper.resetDataProtectionSupportCache()
    }

    private func testKey(_ name: String) -> String {
        "\(Self.testPrefix)-\(name)"
    }

    @Test(
        "save and load roundtrip",
        .disabled(
            if: KeychainTestSupport.disableMutatingTests,
            "Requires writable user-keychain access; headless runners may return errSecInteractionNotAllowed."
        )
    )
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

    @Test(
        "save overwrites existing value",
        .disabled(
            if: KeychainTestSupport.disableMutatingTests,
            "Requires writable user-keychain access; headless runners may return errSecInteractionNotAllowed."
        )
    )
    func saveOverwrite() throws {
        let key = testKey("overwrite")
        defer { try? KeychainHelper.delete(key: key) }

        try KeychainHelper.saveString(key: key, value: "first")
        try KeychainHelper.saveString(key: key, value: "second")
        let loaded = try KeychainHelper.loadString(key: key)
        #expect(loaded == "second")
    }

    @Test(
        "delete removes item",
        .disabled(
            if: KeychainTestSupport.disableMutatingTests,
            "Requires writable user-keychain access; headless runners may return errSecInteractionNotAllowed."
        )
    )
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

    @Test(
        "save and load binary data",
        .disabled(
            if: KeychainTestSupport.disableMutatingTests,
            "Requires writable user-keychain access; headless runners may return errSecInteractionNotAllowed."
        )
    )
    func binaryRoundtrip() throws {
        let key = testKey("binary")
        defer { try? KeychainHelper.delete(key: key) }

        let data = Data([0x00, 0xFF, 0x42, 0x13])
        try KeychainHelper.save(key: key, data: data)
        let loaded = try KeychainHelper.load(key: key)
        #expect(loaded == data)
    }

    @Test(
        "falls back when data protection keychain is unsupported",
        .disabled(
            if: KeychainTestSupport.disableMutatingTests,
            "Requires writable user-keychain access; headless runners may return errSecInteractionNotAllowed."
        )
    )
    func fallsBackWithoutEntitlement() throws {
        let key = testKey("dp-fallback")
        KeychainHelper.useDataProtection = true
        defer {
            try? KeychainHelper.delete(key: key)
            KeychainHelper.useDataProtection = false
            KeychainHelper.resetDataProtectionSupportCache()
        }

        try KeychainHelper.saveString(key: key, value: "fallback")
        let loaded = try KeychainHelper.loadString(key: key)
        #expect(loaded == "fallback")

        try KeychainHelper.delete(key: key)
        let deleted = try KeychainHelper.loadString(key: key)
        #expect(deleted == nil)
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
