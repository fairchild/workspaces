//
//  WebSourceValidation.swift
//  WorkspaceManagerCore
//
//  URL/domain normalization and host policy helpers for embedded web sources.
//

import Foundation

public struct NormalizedWebSourceURL: Equatable, Sendable {
    public let baseURL: URL
    public let allowedHost: String

    public init(baseURL: URL, allowedHost: String) {
        self.baseURL = baseURL
        self.allowedHost = allowedHost
    }
}

public enum WebSourceValidationError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case invalidURL
    case unsupportedScheme(String)
    case missingHost

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter a URL."
        case .invalidURL:
            return "Enter a valid URL."
        case .unsupportedScheme(let scheme):
            return "Only http and https URLs are supported (received: \(scheme))."
        case .missingHost:
            return "URL must include a domain."
        }
    }
}

public enum WebSourceValidation {
    public static func normalizeBaseURL(_ rawValue: String) throws -> NormalizedWebSourceURL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebSourceValidationError.emptyInput
        }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate) else {
            throw WebSourceValidationError.invalidURL
        }

        guard let rawScheme = components.scheme?.lowercased() else {
            throw WebSourceValidationError.invalidURL
        }

        guard rawScheme == "http" || rawScheme == "https" else {
            throw WebSourceValidationError.unsupportedScheme(rawScheme)
        }

        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw WebSourceValidationError.missingHost
        }

        components.user = nil
        components.password = nil
        components.fragment = nil
        components.query = nil
        components.percentEncodedPath = "/"

        guard let normalizedURL = components.url else {
            throw WebSourceValidationError.invalidURL
        }

        return NormalizedWebSourceURL(
            baseURL: normalizedURL,
            allowedHost: host
        )
    }

    public static func normalizedDisplayName(
        explicitName rawName: String,
        baseURL: URL
    ) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return baseURL.host ?? baseURL.absoluteString
    }

    public static func faviconURL(baseURL: URL) -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = baseURL.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = baseURL.port
        components.path = "/favicon.ico"
        return components.url
    }

    public static func host(
        _ candidateHost: String,
        isAllowedFor allowedHost: String,
        allowsSubdomains: Bool
    ) -> Bool {
        let normalizedCandidate = candidateHost.lowercased()
        let normalizedAllowed = allowedHost.lowercased()

        guard !normalizedCandidate.isEmpty, !normalizedAllowed.isEmpty else {
            return false
        }

        if normalizedCandidate == normalizedAllowed {
            return true
        }

        guard allowsSubdomains else {
            return false
        }

        return normalizedCandidate.hasSuffix(".\(normalizedAllowed)")
    }
}
