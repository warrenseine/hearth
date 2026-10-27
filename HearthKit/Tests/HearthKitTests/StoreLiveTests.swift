import Testing
import Foundation
@testable import HearthKit

@Suite("LogStreamer")
@MainActor
struct LogStreamerTests {
    @Test("splits multi-line messages, strips ANSI, caps the buffer")
    func buffering() {
        let streamer = LogStreamer(maxLines: 3)
        streamer.receive(LogMessage(message: "\u{1B}[32mone\u{1B}[0m\ntwo\n", processName: "a"))
        streamer.receive(LogMessage(message: "three", processName: "b"))
        streamer.receive(LogMessage(message: "four", processName: "b"))
        streamer.flush()
        #expect(streamer.lines.map(\.text) == ["two", "three", "four"])
        #expect(streamer.lines.map(\.process) == ["a", "b", "b"])
        #expect(Set(streamer.lines.map(\.id)).count == 3)
    }
}

@Suite("HearthStore against a real process-compose", .serialized, .enabled(if: LiveServer.binary != nil))
@MainActor
struct StoreLiveTests {
    @Test("register, up, see processes live, stop/start one, down")
    func fullCycle() async throws {
        let dir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        version: "0.5"
        processes:
          ticker:
            command: 'while true; do echo "tick"; sleep 0.3; done'
          server:
            command: python3 -m http.server 0 --bind 127.0.0.1
        """.write(to: dir.appendingPathComponent("process-compose.yaml"), atomically: true, encoding: .utf8)

        let registryURL = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        let store = HearthStore(registry: try ProjectRegistry(storeURL: registryURL))
        await store.reloadProjects()
        let project = try await store.addProject(directory: dir).get()
        #expect(store.entries.contains { $0.project?.id == project.id && !$0.isRunning })

        await store.up(project)
        #expect(store.lastError == nil, "\(store.lastError ?? "")")
        let entry = try #require(store.entries.first { $0.project?.id == project.id })
        let connection = try #require(entry.connection)
        #expect(entry.isOwned)
        connection.start()
        try await waitUntil { connection.processes.count == 2 && connection.processes.allSatisfy(\.isRunning) }
        #expect(connection.status == .connected)

        try await waitUntil {
            await connection.refresh()
            return connection.ports["server"]?.isEmpty == false
        }

        let logs = LogStreamer()
        logs.start(client: connection.client, processes: ["ticker"], tail: 5)
        try await waitUntil { logs.flush(); return logs.lines.contains { $0.text == "tick" } }
        logs.stop()

        await connection.stop("ticker")
        try await waitUntil { connection.processes.first { $0.name == "ticker" }?.canStart == true }
        await connection.start("ticker")
        try await waitUntil { connection.processes.first { $0.name == "ticker" }?.isRunning == true }
        #expect(connection.lastActionError == nil)

        await store.down(entry)
        #expect(store.entries.first { $0.project?.id == project.id }?.isRunning == false)
        try? FileManager.default.removeItem(at: Launcher.logFile(projectID: project.id))
    }
}
