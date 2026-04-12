import Foundation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlersBySessionID: [String: [String: (URLRequest) -> (Data, HTTPURLResponse)]] =
        [:]

    /// Create a URLSession with mock handlers keyed by URL path.
    /// Each session gets its own handler namespace, safe for concurrent tests.
    static func session(
        handlers: [String: (json: [String: Any], statusCode: Int)]
    ) -> URLSession {
        let sessionID = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Mock-Session-ID": sessionID]

        var resolved: [String: (URLRequest) -> (Data, HTTPURLResponse)] = [:]
        for (path, spec) in handlers {
            let data = try! JSONSerialization.data(withJSONObject: spec.json)
            let statusCode = spec.statusCode
            resolved[path] = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (data, response)
            }
        }

        lock.lock()
        handlersBySessionID[sessionID] = resolved
        lock.unlock()

        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let sessionID = request.value(forHTTPHeaderField: "X-Mock-Session-ID") ?? ""
        let path = request.url?.path ?? ""

        MockURLProtocol.lock.lock()
        let handler = MockURLProtocol.handlersBySessionID[sessionID]?[path]
        MockURLProtocol.lock.unlock()

        if let handler {
            let (data, response) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"mock: no handler\"}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
