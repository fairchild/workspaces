//
//  LumeHTTPClient.swift
//  WorkspaceManagerCore
//
//  Shared transport for talking to the local Lume daemon.
//

import Foundation

protocol LumeHTTPEmptyResponse: Decodable {
    init()
}

struct LumeHTTPClient: Sendable {
    let baseURL: URL

    func request<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Response {
        let url = try url(for: path, queryItems: queryItems)
        let encodedBody = try body.map { try JSONEncoder().encode($0) }
        let (data, statusCode) = try await sendCurlRequest(
            method: method,
            url: url,
            body: encodedBody
        )

        guard (200...299).contains(statusCode) else {
            if let apiError = try? JSONDecoder().decode(LumeHTTPClientAPIError.self, from: data) {
                throw LumeHTTPClientError.server(apiError.message)
            }

            let message = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw LumeHTTPClientError.server(message)
        }

        if let emptyResponseType = Response.self as? any LumeHTTPEmptyResponse.Type {
            // swift-format-ignore: NeverForceUnwrap
            // Safe: emptyResponseType is proven to be Response by the type check above.
            return emptyResponseType.init() as! Response
        }

        guard !data.isEmpty else {
            throw LumeHTTPClientError.emptyResponse
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LumeHTTPClientError.invalidResponse(error.localizedDescription)
        }
    }

    func requestSucceeds(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval = 10,
        urlSession: URLSession = .shared
    ) async -> Bool {
        do {
            _ = try await rawRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                timeout: timeout,
                urlSession: urlSession
            )
            return true
        } catch {
            return false
        }
    }

    func rawRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        timeout: TimeInterval = 10,
        urlSession: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try url(for: path, queryItems: queryItems)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LumeHTTPClientError.invalidResponse("Invalid response from the Lume daemon.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(LumeHTTPClientAPIError.self, from: data) {
                throw LumeHTTPClientError.server(apiError.message)
            }

            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw LumeHTTPClientError.server(message)
        }

        return (data, httpResponse)
    }

    func url(for path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let components =
            path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if components.isEmpty {
            guard !queryItems.isEmpty else {
                return baseURL
            }

            guard var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw LumeHTTPClientError.invalidEndpoint(path)
            }
            baseComponents.queryItems = queryItems
            guard let url = baseComponents.url else {
                throw LumeHTTPClientError.invalidEndpoint(path)
            }
            return url
        }

        let url = components.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: false)
        }
        guard !queryItems.isEmpty else {
            return url
        }
        guard var resolvedComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LumeHTTPClientError.invalidEndpoint(path)
        }
        resolvedComponents.queryItems = queryItems
        guard let resolvedURL = resolvedComponents.url else {
            throw LumeHTTPClientError.invalidEndpoint(path)
        }
        return resolvedURL
    }

    private func sendCurlRequest(
        method: String,
        url: URL,
        body: Data?
    ) async throws -> (Data, Int) {
        let statusMarker = "__LUME_HTTP_STATUS__:"
        var arguments = [
            "--silent",
            "--show-error",
            "--request", method,
            "--url", url.absoluteString,
            "--max-time", "30",
            "--header", "Connection: close",
            "--write-out", "\n\(statusMarker)%{http_code}",
        ]

        let fileManager = FileManager.default
        var temporaryBodyURL: URL?
        if let body {
            let bodyURL = fileManager.temporaryDirectory
                .appendingPathComponent("lume-request-\(UUID().uuidString).json")
            try body.write(to: bodyURL, options: .atomic)
            temporaryBodyURL = bodyURL
            arguments += [
                "--header", "Content-Type: application/json",
                "--data-binary", "@\(bodyURL.path)",
            ]
        }

        defer {
            if let temporaryBodyURL {
                try? fileManager.removeItem(at: temporaryBodyURL)
            }
        }

        // Un-timed by design: curl carries its own transfer limits and Lume calls
        // run under outer deadlines (scripts/check-subprocess-timeouts.py allowlist).
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/curl",
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment
        )

        guard result.success else {
            let message =
                [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                ?? "curl exited with status \(result.exitCode)"
            throw LumeHTTPClientError.transport(message)
        }

        let output = result.stdout
        guard let markerRange = output.range(of: statusMarker, options: .backwards) else {
            throw LumeHTTPClientError.invalidResponse(
                "Lume curl response did not include an HTTP status."
            )
        }

        let bodyString = String(output[..<markerRange.lowerBound])
        let statusString = output[markerRange.upperBound...].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let statusCode = Int(statusString) else {
            throw LumeHTTPClientError.invalidResponse(
                "Lume curl response returned an invalid HTTP status."
            )
        }

        return (Data(bodyString.utf8), statusCode)
    }
}

enum LumeHTTPClientError: LocalizedError, Sendable {
    case invalidEndpoint(String)
    case transport(String)
    case invalidResponse(String)
    case server(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let path):
            return "Invalid Lume endpoint path: \(path)"
        case .transport(let message), .invalidResponse(let message), .server(let message):
            return message
        case .emptyResponse:
            return "Lume returned an empty response."
        }
    }
}

private struct LumeHTTPClientAPIError: Decodable {
    let message: String
}
