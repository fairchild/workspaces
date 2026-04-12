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
    case invalidAllowlistedDomain(String)

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
        case .invalidAllowlistedDomain(let domain):
            return
                "Invalid allowlisted domain '\(domain)'. Use a domain like example.com or wildcard *.example.com."
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

    public static func normalizeAdditionalAllowedDomains(_ rawValue: String) throws -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        let tokens = rawValue.components(separatedBy: separators)

        var normalizedDomains: [String] = []
        var seen = Set<String>()

        for rawToken in tokens {
            let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let normalized = try normalizeAllowlistedDomain(trimmed)
            if seen.insert(normalized).inserted {
                normalizedDomains.append(normalized)
            }
        }

        return normalizedDomains
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

    public static func host(
        _ candidateHost: String,
        matchesAllowlistDomain allowlistedDomain: String
    ) -> Bool {
        let normalizedCandidate = candidateHost.lowercased()
        let normalizedAllowlisted = allowlistedDomain.lowercased()

        guard !normalizedCandidate.isEmpty, !normalizedAllowlisted.isEmpty else {
            return false
        }

        if normalizedAllowlisted.hasPrefix("*.") {
            let wildcardBase = String(normalizedAllowlisted.dropFirst(2))
            guard !wildcardBase.isEmpty else { return false }
            return normalizedCandidate == wildcardBase
                || normalizedCandidate.hasSuffix(".\(wildcardBase)")
        }

        return normalizedCandidate == normalizedAllowlisted
    }

    private static func normalizeAllowlistedDomain(_ rawToken: String) throws -> String {
        let lowercased = rawToken.lowercased()
        if lowercased.hasPrefix("*.") {
            let wildcardBase = String(lowercased.dropFirst(2))
            return "*.\(try normalizeAllowlistedHost(wildcardBase, original: rawToken))"
        }

        return try normalizeAllowlistedHost(lowercased, original: rawToken)
    }

    private static func normalizeAllowlistedHost(_ rawHost: String, original: String) throws -> String {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix(".") {
            host.removeLast()
        }

        guard !host.isEmpty else {
            throw WebSourceValidationError.invalidAllowlistedDomain(original)
        }
        guard
            !host.contains("*"),
            !host.contains("/"),
            !host.contains("?"),
            !host.contains("#"),
            !host.contains(":")
        else {
            throw WebSourceValidationError.invalidAllowlistedDomain(original)
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            throw WebSourceValidationError.invalidAllowlistedDomain(original)
        }

        for label in labels {
            guard !label.isEmpty else {
                throw WebSourceValidationError.invalidAllowlistedDomain(original)
            }

            let scalarValues = label.unicodeScalars
            guard
                let first = scalarValues.first,
                let last = scalarValues.last,
                first.isASCII,
                last.isASCII
            else {
                throw WebSourceValidationError.invalidAllowlistedDomain(original)
            }

            let isAlnum: (UnicodeScalar) -> Bool = { scalar in
                (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
            }

            guard isAlnum(first), isAlnum(last) else {
                throw WebSourceValidationError.invalidAllowlistedDomain(original)
            }

            for scalar in scalarValues {
                guard scalar.isASCII else {
                    throw WebSourceValidationError.invalidAllowlistedDomain(original)
                }
                let value = scalar.value
                let isDigit = value >= 48 && value <= 57
                let isLowerAlpha = value >= 97 && value <= 122
                let isHyphen = value == 45
                guard isDigit || isLowerAlpha || isHyphen else {
                    throw WebSourceValidationError.invalidAllowlistedDomain(original)
                }
            }
        }

        return host
    }
}
