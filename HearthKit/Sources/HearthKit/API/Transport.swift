import Foundation
import Network

/// Where a process-compose server listens: its unix domain socket (`-U`/`-u`) or a TCP
/// address (`-p`, default `localhost:8080`).
public enum Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    case unix(path: String)
    case tcp(host: String, port: Int)

    public var description: String {
        switch self {
        case .unix(let path): path
        case .tcp(let host, let port): "\(host):\(port)"
        }
    }

    /// A short label for UI badges.
    public var kindLabel: String {
        switch self {
        case .unix: "socket"
        case .tcp: "tcp"
        }
    }

    var nwEndpoint: NWEndpoint {
        switch self {
        case .unix(let path):
            return .unix(path: path)
        case .tcp(let host, let port):
            return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)))
        }
    }

    /// The `-u <path>` / `-p <port> -a <host>` flags that point a process-compose *client*
    /// command (`attach`, `process list`, …) at this server.
    public var clientFlags: [String] {
        switch self {
        case .unix(let path): ["-u", path]
        case .tcp(let host, let port): ["-a", host, "-p", String(port)]
        }
    }
}

public enum PCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Couldn't connect at all: socket file gone, connection refused, timeout.
    case unreachable(String)
    /// 401: the server was started with `PC_API_TOKEN`/`--token-file` and ours is missing or wrong.
    case unauthorized
    /// Any other non-2xx, with process-compose's `{"error": "..."}` message when present.
    case http(status: Int, message: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .unreachable(let detail): "server unreachable: \(detail)"
        case .unauthorized: "the server requires an API token"
        case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : message
        case .malformedResponse(let detail): "unexpected response: \(detail)"
        }
    }
}

/// A bidirectional byte stream to an `Endpoint`, as plain async calls over `NWConnection`.
///
/// One code path for both transports, rather than `URLSession` for TCP plus something else for
/// unix sockets: `URLSession` can't speak to a unix socket at all, and `NWProtocolWebSocket`
/// takes its request path from a URL endpoint, which a `.unix(path:)` endpoint doesn't have. So
/// HTTP/1.1 and the WebSocket framing are done by hand on top (`HTTPWire`, `WebSocketWire`).
final class ByteConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ai.hearth.connection")

    init(endpoint: Endpoint) {
        connection = NWConnection(to: endpoint.nwEndpoint, using: .tcp)
    }

    func open(timeout: Duration = .seconds(3)) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error):
                    once.run { continuation.resume(throwing: PCError.unreachable(error.localizedDescription)) }
                case .waiting(let error):
                    // NWConnection parks in .waiting and retries forever on ECONNREFUSED/ENOENT
                    // (a stale socket file, a stopped server); for a local API that's just "down".
                    connection.cancel()
                    once.run { continuation.resume(throwing: PCError.unreachable(error.localizedDescription)) }
                case .cancelled:
                    once.run { continuation.resume(throwing: PCError.unreachable("cancelled")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { [connection] in
                once.run {
                    connection.cancel()
                    continuation.resume(throwing: PCError.unreachable("timed out"))
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PCError.unreachable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// The next chunk of bytes, or `nil` once the peer has closed its side.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: PCError.unreachable(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// Guards a continuation that several racing callbacks (state changes, a timeout) may try to
/// resume.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

// MARK: - HTTP/1.1

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}

/// Request encoding and response parsing for the small slice of HTTP/1.1 process-compose's Go
/// `net/http` server actually uses: one request per connection (`Connection: close`), bodies
/// framed by `Content-Length` or `Transfer-Encoding: chunked`.
enum HTTPWire {
    static func encodeRequest(method: String, path: String, token: String?, body: Data?, extraHeaders: [(String, String)] = []) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nUser-Agent: Hearth\r\n"
        if let token { head += "X-PC-Token-Key: \(token)\r\n" }
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method != "GET" {
            head += "Content-Length: 0\r\n"
        }
        if extraHeaders.isEmpty { head += "Connection: close\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Parses the status line and headers. Returns `nil` until the full header block arrived.
    static func parseHead(_ buffer: Data) throws -> (status: Int, headers: [String: String], bodyStart: Int)? {
        guard let range = buffer.range(of: headerTerminator) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw PCError.malformedResponse("bad status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (status, headers, range.upperBound - buffer.startIndex)
    }

    /// Returns the complete response once `buffer` holds all of it, `nil` if more bytes are
    /// needed. With `atEOF`, a body without a length is taken as everything received.
    static func parseResponse(_ buffer: Data, atEOF: Bool) throws -> HTTPResponse? {
        guard let head = try parseHead(buffer) else {
            if atEOF { throw PCError.malformedResponse("connection closed before headers") }
            return nil
        }
        let rest = Data(buffer[(buffer.startIndex + head.bodyStart)...])
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = try decodeChunked(rest) else {
                if atEOF { throw PCError.malformedResponse("truncated chunked body") }
                return nil
            }
            return HTTPResponse(status: head.status, headers: head.headers, body: body)
        }
        if let lengthText = head.headers["content-length"], let length = Int(lengthText) {
            guard rest.count >= length else {
                if atEOF { throw PCError.malformedResponse("truncated body") }
                return nil
            }
            return HTTPResponse(status: head.status, headers: head.headers, body: rest.prefix(length))
        }
        return atEOF ? HTTPResponse(status: head.status, headers: head.headers, body: rest) : nil
    }

    /// Decodes a chunked body; `nil` if the terminating zero-length chunk hasn't arrived yet.
    static func decodeChunked(_ data: Data) throws -> Data? {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                throw PCError.malformedResponse("bad chunk size: \(sizeText)")
            }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return body }
            guard data.endIndex - chunkStart >= size + 2 else { return nil }
            body.append(data[chunkStart..<(chunkStart + size)])
            index = chunkStart + size + 2
        }
    }
}

// MARK: - WebSocket (RFC 6455, client side)

enum WebSocketWire {
    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    struct Frame: Equatable {
        let fin: Bool
        let opcode: Opcode
        let payload: Data
    }

    static func handshakeRequest(path: String, token: String?) -> Data {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        return HTTPWire.encodeRequest(method: "GET", path: path, token: token, body: nil, extraHeaders: [
            ("Upgrade", "websocket"),
            ("Connection", "Upgrade"),
            ("Sec-WebSocket-Key", key),
            ("Sec-WebSocket-Version", "13"),
        ])
    }

    /// Client→server frames must be masked (RFC 6455 §5.3).
    static func encodeClientFrame(opcode: Opcode, payload: Data = Data()) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((length >> ($0 * 8)) & 0xFF) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// Incremental frame decoder for server→client frames, which arrive unmasked but may be
    /// split or coalesced arbitrarily across reads.
    struct Parser {
        private var buffer = Data()

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        mutating func next() throws -> Frame? {
            let bytes = buffer
            guard bytes.count >= 2 else { return nil }
            let b0 = bytes[bytes.startIndex]
            let b1 = bytes[bytes.startIndex + 1]
            guard let opcode = Opcode(rawValue: b0 & 0x0F) else {
                throw PCError.malformedResponse("unknown websocket opcode \(b0 & 0x0F)")
            }
            var offset = 2
            var length = Int(b1 & 0x7F)
            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = Int(bytes[bytes.startIndex + 2]) << 8 | Int(bytes[bytes.startIndex + 3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[bytes.startIndex + $1]) }
                offset = 10
            }
            let masked = b1 & 0x80 != 0
            var mask: [UInt8] = []
            if masked {
                guard bytes.count >= offset + 4 else { return nil }
                mask = Array(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + 4)])
                offset += 4
            }
            guard bytes.count >= offset + length else { return nil }
            var payload = Data(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + length)])
            if masked {
                payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            }
            buffer = Data(bytes[(bytes.startIndex + offset + length)...])
            return Frame(fin: b0 & 0x80 != 0, opcode: opcode, payload: payload)
        }
    }
}

// MARK: - Client-facing transport

/// Issues one HTTP request per connection, and opens long-lived WebSocket streams.
public struct Transport: Sendable {
    public let endpoint: Endpoint
    public let token: String?
    public var timeout: Duration

    public init(endpoint: Endpoint, token: String? = nil, timeout: Duration = .seconds(5)) {
        self.endpoint = endpoint
        self.token = token
        self.timeout = timeout
    }

    /// `responseTimeout` overrides how long to wait for the reply once connected; connecting
    /// always uses `timeout`, so a dead server still fails fast.
    public func request(
        _ method: String, _ path: String, body: Data? = nil, responseTimeout: Duration? = nil
    ) async throws -> HTTPResponse {
        let connection = ByteConnection(endpoint: endpoint)
        defer { connection.cancel() }
        let timeout = self.timeout
        let overall = responseTimeout.map { timeout + $0 } ?? timeout
        return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask {
                try await connection.open(timeout: timeout)
                try await connection.send(HTTPWire.encodeRequest(method: method, path: path, token: token, body: body))
                var buffer = Data()
                while true {
                    guard let chunk = try await connection.receive() else {
                        // Force-unwrap is safe: with atEOF the parser either returns or throws.
                        return try HTTPWire.parseResponse(buffer, atEOF: true)!
                    }
                    buffer.append(chunk)
                    if let response = try HTTPWire.parseResponse(buffer, atEOF: false) {
                        return response
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: overall)
                throw PCError.unreachable("request timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Streams the text frames of a WebSocket endpoint until the server closes it, the
    /// connection drops (the stream then throws), or the consumer cancels.
    public func webSocket(_ path: String) -> AsyncThrowingStream<String, Error> {
        let endpoint = self.endpoint
        let token = self.token
        return AsyncThrowingStream { continuation in
            let connection = ByteConnection(endpoint: endpoint)
            let task = Task {
                do {
                    try await connection.open()
                    try await connection.send(WebSocketWire.handshakeRequest(path: path, token: token))
                    var buffer = Data()
                    var head: (status: Int, headers: [String: String], bodyStart: Int)?
                    while head == nil {
                        guard let chunk = try await connection.receive() else {
                            throw PCError.unreachable("closed during websocket handshake")
                        }
                        buffer.append(chunk)
                        head = try HTTPWire.parseHead(buffer)
                    }
                    guard let head, head.status == 101 else {
                        if head?.status == 401 { throw PCError.unauthorized }
                        throw PCError.http(status: head?.status ?? 0, message: "websocket upgrade refused")
                    }
                    var parser = WebSocketWire.Parser()
                    parser.append(Data(buffer[(buffer.startIndex + head.bodyStart)...]))
                    var fragments = Data()
                    readLoop: while !Task.isCancelled {
                        while let frame = try parser.next() {
                            switch frame.opcode {
                            case .text, .binary, .continuation:
                                fragments.append(frame.payload)
                                if frame.fin {
                                    continuation.yield(String(decoding: fragments, as: UTF8.self))
                                    fragments.removeAll()
                                }
                            case .ping:
                                try await connection.send(WebSocketWire.encodeClientFrame(opcode: .pong, payload: frame.payload))
                            case .pong:
                                break
                            case .close:
                                try? await connection.send(WebSocketWire.encodeClientFrame(opcode: .close))
                                break readLoop
                            }
                        }
                        guard let chunk = try await connection.receive() else { break }
                        parser.append(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                connection.cancel()
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.cancel()
            }
        }
    }
}
