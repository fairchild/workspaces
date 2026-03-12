import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "KeychainHelper")

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
    private static let dataProtectionSupportLock = NSLock()
    private static var cachedDataProtectionSupport: Bool?
    private static var loggedLegacyFallback = false

    /// Use the data protection keychain (macOS 10.15+) to avoid per-application ACL
    /// prompts when different binaries (app vs test runner) access the same items.
    /// Disabled in tests where the SPM test runner lacks signing entitlements.
    static var useDataProtection = true

    private static func query(
        key: String,
        useDataProtectionKeychain: Bool,
        extras: [String: Any] = [:]
    ) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if useDataProtectionKeychain {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        for (k, v) in extras { q[k] = v }
        return q
    }

    private static func effectiveUseDataProtectionKeychain() -> Bool {
        guard useDataProtection else { return false }

        dataProtectionSupportLock.lock()
        if let cachedDataProtectionSupport {
            dataProtectionSupportLock.unlock()
            return cachedDataProtectionSupport
        }

        let supported = probeDataProtectionKeychainSupport()
        cachedDataProtectionSupport = supported
        let shouldLogFallback = !supported && !loggedLegacyFallback
        if shouldLogFallback {
            loggedLegacyFallback = true
        }
        dataProtectionSupportLock.unlock()

        if shouldLogFallback {
            log.warning(
                "Data protection keychain is unavailable for this process; falling back to the legacy keychain. Use a signed app bundle with an embedded provisioning profile and keychain access group entitlements to enable it."
            )
        }
        return supported
    }

    // Probe once per process so ad-hoc/SPM builds fall back cleanly, while
    // entitled app bundles stay on the data protection keychain and avoid legacy ACL prompts.
    private static func probeDataProtectionKeychainSupport() -> Bool {
        let probeKey = "__keychain-capability-probe__-\(UUID().uuidString)"
        let baseQuery = query(key: probeKey, useDataProtectionKeychain: true)
        let addQuery = query(
            key: probeKey,
            useDataProtectionKeychain: true,
            extras: [
                kSecValueData as String: Data("probe".utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
        )

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            SecItemDelete(baseQuery as CFDictionary)
            return true
        }

        return status != errSecMissingEntitlement
    }

    private static func disableDataProtectionKeychainForProcess() {
        dataProtectionSupportLock.lock()
        cachedDataProtectionSupport = false
        let shouldLog = !loggedLegacyFallback
        loggedLegacyFallback = true
        dataProtectionSupportLock.unlock()

        if shouldLog {
            log.warning(
                "Data protection keychain is unavailable for this process; falling back to the legacy keychain. Use a signed app bundle with an embedded provisioning profile and keychain access group entitlements to enable it."
            )
        }
    }

    static func resetDataProtectionSupportCache() {
        dataProtectionSupportLock.lock()
        cachedDataProtectionSupport = nil
        loggedLegacyFallback = false
        dataProtectionSupportLock.unlock()
    }

    public static func save(key: String, data: Data) throws {
        try save(
            key: key,
            data: data,
            useDataProtectionKeychain: effectiveUseDataProtectionKeychain()
        )
    }

    private static func save(key: String, data: Data, useDataProtectionKeychain: Bool) throws {
        let baseQuery = query(key: key, useDataProtectionKeychain: useDataProtectionKeychain)

        // Try deleting any existing item first
        SecItemDelete(baseQuery as CFDictionary)

        let addQuery = query(
            key: key,
            useDataProtectionKeychain: useDataProtectionKeychain,
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
            if shouldFallbackToLegacyKeychain(
                after: updateStatus,
                attemptedDataProtection: useDataProtectionKeychain
            ) {
                disableDataProtectionKeychainForProcess()
                try save(key: key, data: data, useDataProtectionKeychain: false)
                return
            }
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
            return
        }

        if shouldFallbackToLegacyKeychain(
            after: status,
            attemptedDataProtection: useDataProtectionKeychain
        ) {
            disableDataProtectionKeychainForProcess()
            try save(key: key, data: data, useDataProtectionKeychain: false)
            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public static func load(key: String) throws -> Data? {
        try load(key: key, useDataProtectionKeychain: effectiveUseDataProtectionKeychain())
    }

    private static func load(key: String, useDataProtectionKeychain: Bool) throws -> Data? {
        let q = query(
            key: key,
            useDataProtectionKeychain: useDataProtectionKeychain,
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
            if shouldFallbackToLegacyKeychain(
                after: status,
                attemptedDataProtection: useDataProtectionKeychain
            ) {
                disableDataProtectionKeychainForProcess()
                return try load(key: key, useDataProtectionKeychain: false)
            }
            throw KeychainError.loadFailed(status)
        }
    }

    public static func delete(key: String) throws {
        try delete(key: key, useDataProtectionKeychain: effectiveUseDataProtectionKeychain())
    }

    private static func delete(key: String, useDataProtectionKeychain: Bool) throws {
        let q = query(key: key, useDataProtectionKeychain: useDataProtectionKeychain)

        let status = SecItemDelete(q as CFDictionary)
        if shouldFallbackToLegacyKeychain(
            after: status,
            attemptedDataProtection: useDataProtectionKeychain
        ) {
            disableDataProtectionKeychainForProcess()
            try delete(key: key, useDataProtectionKeychain: false)
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private static func shouldFallbackToLegacyKeychain(
        after status: OSStatus,
        attemptedDataProtection: Bool
    ) -> Bool {
        attemptedDataProtection && status == errSecMissingEntitlement
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
