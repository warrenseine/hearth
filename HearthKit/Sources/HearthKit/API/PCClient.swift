import Foundation

/// Typed wrapper over process-compose's REST + WebSocket API (see its swagger at
/// `src/docs/swagger.yaml` upstream). Stateless: every call opens its own connection.
public struct PCClient: Sendable {
    public let transport: Transport

    public init(endpoint: Endpoint, token: String? = nil) {
        transport = Transport(endpoint: endpoint, token: token)
    }

    public init(transport: Transport) {
        self.transport = transport
    }

    // MARK: Reads

    /// `GET /live`. Throws `PCError.unauthorized` for a token-protected server — the cheapest
    /// way to tell "up but locked" from "down".
    public func live() async throws {
        _ = try await call("GET", "/live")
    }

    public func projectState() async throws -> ProjectState {
        try decode(ProjectState.self, from: try await call("GET", "/project/state"))
    }

    public func processes() async throws -> [ProcessState] {
        try decode(ProcessesEnvelope.self, from: try await call("GET", "/processes")).data
    }

    public func process(_ name: String) async throws -> ProcessState {
        try decode(ProcessState.self, from: try await call("GET", "/process/\(escape(name))"))
    }

    public func config(_ name: String) async throws -> ProcessConfig {
        try ProcessConfig(data: try await call("GET", "/process/info/\(escape(name))"))
    }

    public func ports(_ name: String) async throws -> ProcessPorts {
        try decode(ProcessPorts.self, from: try await call("GET", "/process/ports/\(escape(name))"))
    }

    /// The last `limit` buffered lines, `endOffset` lines back from the newest.
    public func logs(_ name: String, endOffset: Int = 0, limit: Int = 1000) async throws -> [String] {
        struct Envelope: Decodable { let logs: [String] }
        return try decode(Envelope.self, from: try await call("GET", "/process/logs/\(escape(name))/\(endOffset)/\(limit)")).logs
    }

    // MARK: Actions

    public func start(_ name: String) async throws {
        _ = try await call("POST", "/process/start/\(escape(name))")
    }

    public func stop(_ name: String) async throws {
        _ = try await call("PATCH", "/process/stop/\(escape(name))", waitingForExit: true)
    }

    public func restart(_ name: String) async throws {
        _ = try await call("POST", "/process/restart/\(escape(name))", waitingForExit: true)
    }

    /// Re-reads the project's config files from disk and applies the difference.
    public func reloadConfiguration() async throws {
        _ = try await call("POST", "/project/configuration")
    }

    /// Stops every process and shuts the server itself down (what `process-compose down` does).
    public func stopProject() async throws {
        _ = try await call("POST", "/project/stop", waitingForExit: true)
    }

    // MARK: Streams

    /// `GET /process/states/ws`: one `snapshot` event per process on connect, then one event per
    /// status/health transition. Finishes (or throws) when the server goes away.
    public func stateEvents() -> AsyncThrowingStream<ProcessStateEvent, Error> {
        decodedStream(transport.webSocket("/process/states/ws"), as: ProcessStateEvent.self)
    }

    /// `GET /process/logs/ws`: the last `tail` lines of each named process, then new lines as
    /// they're written when `follow` is set.
    public func logStream(processes: [String], tail: Int = 1000, follow: Bool = true) -> AsyncThrowingStream<LogMessage, Error> {
        let names = processes.map(escapeQuery).joined(separator: ",")
        return decodedStream(transport.webSocket("/process/logs/ws?name=\(names)&offset=\(tail)&follow=\(follow)"), as: LogMessage.self)
    }

    // MARK: Plumbing

    /// How long stop/restart may take to answer. process-compose replies only once the
    /// processes have exited, which for one that ignores SIGTERM means its whole
    /// `shutdown.timeout_seconds` (default 10s, often set higher) before the SIGKILL.
    static let exitTimeout: Duration = .seconds(120)

    private func call(_ method: String, _ path: String, body: Data? = nil, waitingForExit: Bool = false) async throws -> Data {
        let response = try await transport.request(
            method, path, body: body, responseTimeout: waitingForExit ? Self.exitTimeout : nil
        )
        switch response.status {
        case 200..<300:
            return response.body
        case 401:
            throw PCError.unauthorized
        default:
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body))?.error
                ?? String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PCError.http(status: response.status, message: message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PCError.malformedResponse("\(T.self): \(error)")
        }
    }

    private func decodedStream<T: Decodable & Sendable>(_ frames: AsyncThrowingStream<String, Error>, as type: T.Type) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames {
                        // Undecodable frames are skipped, not fatal: one odd event shouldn't
                        // tear down a live log or state stream.
                        if let value = try? JSONDecoder().decode(type, from: Data(frame.utf8)) {
                            continuation.yield(value)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=,+")
        return set
    }()

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? component
    }

    private func escapeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? value
    }
}
