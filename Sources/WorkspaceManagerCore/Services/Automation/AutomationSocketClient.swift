import Darwin
import Foundation

public struct AutomationSocketClient: Sendable {
    public struct Response: Sendable, Equatable {
        public let statusCode: Int
        public let body: Data

        public init(statusCode: Int, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }
    }

    public enum ClientError: LocalizedError, Sendable, Equatable {
        case socketPathTooLong
        case socketOpenFailed(Int32)
        case connectFailed(String, Int32)
        case writeFailed(Int32)
        case readFailed(Int32)
        case timedOut(TimeInterval)
        case invalidHTTPResponse

        public var errorDescription: String? {
            switch self {
            case .socketPathTooLong:
                return "Automation socket path is too long."
            case .socketOpenFailed(let code):
                return "Could not open Unix socket: errno=\(code)."
            case .connectFailed(let path, let code):
                return "Could not connect to WorkSpaces Automation API at \(path): errno=\(code)."
            case .writeFailed(let code):
                return "Could not write automation request: errno=\(code)."
            case .readFailed(let code):
                return "Could not read automation response: errno=\(code)."
            case .timedOut(let seconds):
                return "WorkSpaces Automation API did not respond within \(Int(seconds))s. "
                    + "The app may be busy or hung; try again once it is responsive."
            case .invalidHTTPResponse:
                return "WorkSpaces Automation API returned an invalid HTTP response."
            }
        }
    }

    public let socketPath: String
    /// Socket-level send/receive deadline (SO_SNDTIMEO/SO_RCVTIMEO). A hung app surfaces as a
    /// typed `timedOut` error instead of blocking the calling shell indefinitely.
    public let timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func request(
        method: String,
        path: String,
        handle: String? = nil,
        body: Data = Data()
    ) throws -> Response {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socketOpenFailed(errno) }
        defer { close(fd) }
        applyTimeouts(fd: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw ClientError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for index in 0..<capacity {
                    buffer[index] = 0
                }
                for (index, byte) in pathBytes.enumerated() {
                    buffer[index] = CChar(bitPattern: byte)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    fd,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
                )
            }
        }
        guard connectResult == 0 else {
            throw ClientError.connectFailed(socketPath, errno)
        }

        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: localhost\r\n"
        request += "Accept: application/json\r\n"
        request += "Connection: close\r\n"
        if let handle, !handle.isEmpty {
            request += "X-WorkSpaces-Automation-Handle: \(handle)\r\n"
        }
        if !body.isEmpty {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        } else {
            request += "Content-Length: 0\r\n"
        }
        request += "\r\n"

        var outbound = Data(request.utf8)
        outbound.append(body)
        try writeAll(outbound, fd: fd)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                responseData.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ClientError.timedOut(timeout)
            } else {
                throw ClientError.readFailed(errno)
            }
        }

        return try parseHTTPResponse(responseData)
    }

    private func applyTimeouts(fd: Int32) {
        var deadline = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, size)
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: written),
                    data.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0 && errno == EINTR {
                    continue
                } else if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw ClientError.timedOut(timeout)
                } else {
                    throw ClientError.writeFailed(errno)
                }
            }
        }
    }

    private func parseHTTPResponse(_ data: Data) throws -> Response {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw ClientError.invalidHTTPResponse
        }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw ClientError.invalidHTTPResponse
        }
        guard let statusLine = header.split(separator: "\r\n").first else {
            throw ClientError.invalidHTTPResponse
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw ClientError.invalidHTTPResponse
        }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        return Response(statusCode: statusCode, body: body)
    }
}
