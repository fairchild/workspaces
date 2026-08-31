// A paired agent-capable node and its Keychain-backed store. Session
// identity is namespaced by node from the first commit (ADR condition 3):
// the pair (baseURL, sessionId) is the identity, never a bare sessionId.
import Foundation
import Security

struct Node: Codable, Equatable {
    var baseURL: URL
    var token: String

    var host: String { baseURL.host ?? baseURL.absoluteString }

    /// The browser-convenience sign-in URL: token in query, cookie comes back.
    /// The bearer-header contract path arrives with /api/node in Phase 2.
    func signInURL(redirect: String = "/") -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/sign-in"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "redirect", value: redirect),
        ]
        return components.url!
    }

    func healthzURL() -> URL {
        baseURL.appending(path: "/api/healthz")
    }
}

/// Keychain persistence for the paired node — the token never touches
/// UserDefaults. One node today; the store shape stays a single record
/// keyed by account so a node list can replace it without migration.
@MainActor
final class NodeStore: ObservableObject {
    @Published private(set) var node: Node?

    private static let service = "com.cloudcompute.workspaces.mobile.node"
    private static let account = "default-node"

    init() {
        node = Self.read()
    }

    func save(_ node: Node) {
        let data = try? JSONEncoder().encode(node)
        guard let data else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
        self.node = node
    }

    func unpair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
        node = nil
    }

    private static func read() -> Node? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Node.self, from: data)
    }
}
