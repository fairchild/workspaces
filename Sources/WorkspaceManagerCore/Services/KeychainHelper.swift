import Foundation
import Security

public enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Keychain save failed (OSStatus \(status))"
        case .loadFailed(let status):
            "Keychain load failed (OSStatus \(status))"
        case .deleteFailed(let status):
            "Keychain delete failed (OSStatus \(status))"
        case .unexpectedData:
            "Keychain returned unexpected data"
        }
    }
}

public enum KeychainHelper {
    private static let service = "com.cloudcompute.workspaces"

    /// Use the data protection keychain (macOS 10.15+) to avoid per-application ACL
    /// prompts when different binaries (app vs test runner) access the same items.
    /// Disabled in tests where the SPM test runner lacks signing entitlements.
    static var useDataProtection = true

    private static func query(key: String, extras: [String: Any] = [:]) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if useDataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        for (k, v) in extras { q[k] = v }
        return q
    }

    public static func save(key: String, data: Data) throws {
        let baseQuery = query(key: key)

        // Try deleting any existing item first
        SecItemDelete(baseQuery as CFDictionary)

        let addQuery = query(
            key: key,
            extras: [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
        )

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Delete failed silently (e.g. item owned by different signing identity).
            // Fall back to update-in-place.
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public static func load(key: String) throws -> Data? {
        let q = query(
            key: key,
            extras: [
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
        )

        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    public static func delete(key: String) throws {
        let q = query(key: key)

        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    public static func saveString(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        try save(key: key, data: data)
    }

    public static func loadString(key: String) throws -> String? {
        guard let data = try load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
