import Foundation

public enum NotificationConstants {
    public static let baseURL: URL = {
        if let override = ProcessInfo.processInfo.environment[
            "WORKSPACES_NOTIFICATION_URL"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://webhooks.cloudcompute.com")!
    }()
    public static let gitHubAppClientID = "Iv23liJBRgQoWIWjtRoO"

    public static let enabledKey = "notificationsEnabled"
    public static let defaultEnabled = false

    public static let keychainJWTKey = "com.cloudcompute.workspaces.notification-jwt"
    public static let keychainLoginKey = "com.cloudcompute.workspaces.notification-login"
    public static let keychainGitHubTokenKey = "com.cloudcompute.workspaces.github-token"
    public static let keychainJWTExpiryKey = "com.cloudcompute.workspaces.notification-jwt-expiry"
}
