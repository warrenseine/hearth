import Testing
import Foundation
@testable import HearthKit

/// End-to-end against a real `process-compose` binary, over both a unix socket and TCP. Skipped
/// when the binary isn't installed (e.g. on CI).
@Suite("Live process-compose server", .serialized, .enabled(if: LiveServer.binary != nil))
struct LiveServerTests {
    @Test("REST reads, actions and both websocket streams over a unix socket")
    func overUnixSocket() async throws {
        let server = try await LiveServer.start(.socket)
        defer { server.shutdown() }
        let client = PCClient(endpoint: server.endpoint)

        try await client.live()
        let state = try await client.projectState()
        #expect(state.processNum == 2)

        let names = try await client.processes().map(\.name).sorted()
        #expect(names == ["sleeper", "ticker"])
        #expect(try await client.ports("ticker").name == "ticker")
        #expect(try await client.config("ticker").command?.contains("tick") == true)

        // States stream: a snapshot per process first.
        var snapshots = Set<String>()
        for try await event in client.stateEvents() {
            if event.snapshot { snapshots.insert(event.state.name) }
            if snapshots.count == 2 { break }
        }
        #expect(snapshots == ["sleeper", "ticker"])

        // Logs stream: lines from the ticker arrive.
        var gotTick = false
        for try await message in client.logStream(processes: ["ticker"], tail: 10) {
            if message.message.contains("tick") { gotTick = true; break }
        }
        #expect(gotTick)

        try await client.stop("sleeper")
        try await waitUntil { try await client.process("sleeper").canStart }
        try await client.start("sleeper")
        try await waitUntil { try await client.process("sleeper").isRunning }

        await #expect(throws: PCError.self) { try await client.start("does-not-exist") }
    }

    @Test("TCP with an API token: 401 without it, works with it")
    func overTCPWithToken() async throws {
        let server = try await LiveServer.start(.tcpWithToken)
        defer { server.shutdown() }
        await #expect(throws: PCError.unauthorized) { try await PCClient(endpoint: server.endpoint).live() }
        let client = PCClient(endpoint: server.endpoint, token: LiveServer.token)
        try await client.live()
        #expect(try await client.processes().count == 2)
        try await client.stopProject()
        try await waitUntil {
            do { try await client.live(); return false } catch { return true }
        }
    }

    @Test("an endpoint with nothing listening fails fast as unreachable")
    func unreachable() async throws {
        let client = PCClient(endpoint: .unix(path: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString.prefix(6)).sock").path))
        do {
            try await client.live()
            Issue.record("expected unreachable")
        } catch let error as PCError {
            guard case .unreachable = error else { Issue.record("got \(error)"); return }
        }
    }
}

func waitUntil(isolation: isolated (any Actor)? = #isolation, timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if (try? await condition()) == true { return }
        try await Task.sleep(for: .milliseconds(200))
    }
    Issue.record("condition not met within \(timeout)")
}

struct LiveServer {
    enum Mode { case socket, tcpWithToken }
    static let token = "hearth-test-token-0123456789"

    static var binary: String? { BinaryLocator().locateProcessCompose() }

    let endpoint: Endpoint
    let directory: URL
    let token: String?

    static func start(_ mode: Mode) async throws -> LiveServer {
        let dir = try makeTempDir("live")
        try """
        version: "0.5"
        processes:
          ticker:
            command: 'while true; do echo "tick $$(date +%s)"; sleep 0.3; done'
          sleeper:
            command: sleep 600
        """.write(to: dir.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8)

        var arguments = ["up", "-D", "-t=false", "-f", "process-compose.yaml", "-L", dir.appendingPathComponent("pc.log").path]
        var environment = ProcessInfo.processInfo.environment
        let endpoint: Endpoint
        switch mode {
        case .socket:
            let socket = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-t-\(UUID().uuidString.prefix(6)).sock").path
            arguments += ["-u", socket]
            endpoint = .unix(path: socket)
        case .tcpWithToken:
            let port = Int.random(in: 20_000..<40_000)
            arguments += ["-p", String(port)]
            environment["PC_API_TOKEN"] = token
            endpoint = .tcp(host: "localhost", port: port)
        }
        let result = try await SubprocessRunner().run(executable: binary!, arguments: arguments, currentDirectory: dir, environment: environment)
        guard result.succeeded else {
            throw PCError.unreachable("process-compose up -D failed: \(result.stderr)")
        }
        return LiveServer(endpoint: endpoint, directory: dir, token: mode == .tcpWithToken ? token : nil)
    }

    func shutdown() {
        let endpoint = endpoint, token = token, directory = directory
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await PCClient(endpoint: endpoint, token: token).stopProject()
            try? FileManager.default.removeItem(at: directory)
            done.signal()
        }
        done.wait()
    }
}

@Suite("Launcher + discovery against a real process-compose", .serialized, .enabled(if: LiveServer.binary != nil))
struct LauncherLiveTests {
    @Test("up --detached on an owned socket, found by discovery, then stopped")
    func launchAndDiscover() async throws {
        let dir = try makeTempDir("launch")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "version: \"0.5\"\nprocesses:\n  idle:\n    command: sleep 600\n".write(to: dir.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8)
        let project = ProjectContext(id: "t" + RegisteredProject.makeID().prefix(7), name: "launch-test", directory: dir, configFiles: ["process-compose.yaml"])

        let launcher = Launcher(binary: LiveServer.binary!, environment: ProcessInfo.processInfo.environment)
        let endpoint = try await launcher.up(project)
        defer { try? FileManager.default.removeItem(at: Launcher.logFile(projectID: project.id)) }
        let client = PCClient(endpoint: endpoint)
        try await client.live()

        try await waitUntil { Discovery().scan().contains { $0.endpoint == endpoint } }
        let found = try #require(Discovery().scan().first { $0.endpoint == endpoint })
        #expect(Launcher.ownedProjectID(for: found.endpoint) == project.id)
        #expect(found.configFiles == [dir.appendingPathComponent("process-compose.yaml").path] || found.configFiles.first?.hasSuffix("/process-compose.yaml") == true)

        try await client.stopProject()
        try await waitUntil { !Discovery().scan().contains { $0.endpoint == endpoint } }
    }

    @Test("a broken config surfaces process-compose's error")
    func launchFailure() async throws {
        let dir = try makeTempDir("broken")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "processes: [this is not a map".write(to: dir.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8)
        let project = ProjectContext(id: "t" + RegisteredProject.makeID().prefix(7), name: "broken", directory: dir, configFiles: ["process-compose.yaml"])
        defer { try? FileManager.default.removeItem(at: Launcher.logFile(projectID: project.id)) }
        await #expect(throws: PCError.self) {
            try await Launcher(binary: LiveServer.binary!, environment: ProcessInfo.processInfo.environment).up(project)
        }
    }
}
