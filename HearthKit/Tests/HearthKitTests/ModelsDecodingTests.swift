import Testing
import Foundation
@testable import HearthKit

@Suite("API model decoding against captured process-compose v1.122 payloads")
struct ModelsDecodingTests {
    @Test("decodes /processes")
    func processes() throws {
        let list = try JSONDecoder().decode(ProcessesEnvelope.self, from: TestFixtures.data("processes.json")).data
        #expect(list.map(\.name) == ["web", "worker", "flaky"])
        let web = list[0]
        #expect(web.status == "Running")
        #expect(web.namespace == "default")
        #expect(web.health == .ready)
        #expect(web.phase == .running)
        #expect(web.pid == 73070)
        #expect(web.mem == 32_948_224)
        #expect(web.processStartTime != nil)
        #expect(web.processEndTime == nil)
        #expect(list[1].health == .noProbe)
        let flaky = list[2]
        #expect(flaky.status == "Restarting")
        #expect(flaky.phase == .transitioning)
        #expect(flaky.restarts == 2)
        #expect(flaky.exitCode == 1)
        #expect(!flaky.canStart)
    }

    @Test("decodes /project/state")
    func projectState() throws {
        let state = try JSONDecoder().decode(ProjectState.self, from: TestFixtures.data("project-state.json"))
        #expect(state.version == "v1.122.0")
        #expect(state.processNum == 3)
        #expect(state.runningProcessNum == 2)
        #expect(state.fileNames == ["process-compose.yaml"])
        #expect(state.startTime != nil)
    }

    @Test("decodes /process/ports and /process/info")
    func portsAndConfig() throws {
        let ports = try JSONDecoder().decode(ProcessPorts.self, from: TestFixtures.data("process-ports.json"))
        #expect(ports.tcpPorts == [8765])
        let config = try ProcessConfig(data: TestFixtures.data("process-info.json"))
        #expect(config.command == "python3 -m http.server 8765")
        #expect(config.replicas == 1)
        #expect(!config.prettyJSON.contains("originalConfig"))
        #expect(config.prettyJSON.contains("readinessProbe"))
    }

    @Test("decodes states and logs websocket frames")
    func websocketFrames() throws {
        let events = try TestFixtures.lines("states-ws.jsonl").map { try JSONDecoder().decode(ProcessStateEvent.self, from: Data($0.utf8)) }
        #expect(events.count == 4)
        #expect(events.prefix(3).allSatisfy { $0.snapshot })
        #expect(!events[3].snapshot)
        #expect(events[3].state.name == "flaky")
        let logs = try TestFixtures.lines("logs-ws.jsonl").map { try JSONDecoder().decode(LogMessage.self, from: Data($0.utf8)) }
        #expect(logs.first == LogMessage(message: "flaky crashing", processName: "flaky"))
        #expect(logs.contains { $0.processName == "worker" })
    }

    @Test("parses Go timestamps with any number of fractional digits, and the zero time as nil")
    func dates() {
        let six = PCDate.parse("2026-10-26T20:05:07.133659+01:00")
        let five = PCDate.parse("2026-10-26T20:05:07.13386+01:00")
        let none = PCDate.parse("2026-10-26T20:05:07Z")
        #expect(six != nil && five != nil && none != nil)
        #expect(abs(six!.timeIntervalSince(five!)) < 0.001)
        #expect(PCDate.parse("0001-01-01T00:00:00Z") == nil)
        #expect(PCDate.parse("") == nil)
    }

    @Test("phase maps completed-with-error to failed and a probed-but-unready process to transitioning")
    func phases() {
        #expect(ProcessState(name: "a", status: "Completed", exitCode: 0).phase == .stopped)
        #expect(ProcessState(name: "a", status: "Completed", exitCode: 2).phase == .failed)
        #expect(ProcessState(name: "a", status: "Running", isReady: "Not Ready", hasReadyProbe: true, isRunning: true).phase == .transitioning)
        #expect(ProcessState(name: "a", status: "Disabled").phase == .stopped)
    }
}
