import Foundation
import Observation

/// Live view of one process-compose server: its processes (pushed by the states WebSocket,
/// refreshed by polling for the CPU/memory/age figures the socket doesn't push), project state
/// and listening ports.
@MainActor
@Observable
public final class ServerConnection: Identifiable {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected
        /// Up, but token-protected and we don't have (the right) token.
        case needsToken
        case unreachable(String)
    }

    public nonisolated let endpoint: Endpoint
    public nonisolated var id: Endpoint { endpoint }
    public internal(set) var invocation: ServerInvocation?
    public private(set) var status: Status = .connecting
    public private(set) var project: ProjectState?
    public private(set) var processes: [ProcessState] = []
    public private(set) var ports: [String: [Int]] = [:]
    public private(set) var lastActionError: String?
    /// Process names with a start/stop/restart in flight.
    public private(set) var busy: Set<String> = []

    public private(set) var token: String?
    public var client: PCClient { PCClient(endpoint: endpoint, token: token) }

    private var visible = true
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollTick = 0

    public init(endpoint: Endpoint, invocation: ServerInvocation?, token: String?) {
        self.endpoint = endpoint
        self.invocation = invocation
        self.token = token
    }

    public var runningCount: Int { processes.filter(\.isRunning).count }

    /// Worst-first summary for dots and badges.
    public var overallPhase: ProcessState.Phase {
        guard status == .connected else { return .stopped }
        let phases = processes.map(\.phase)
        if phases.contains(.failed) { return .failed }
        if phases.contains(.transitioning) { return .transitioning }
        if phases.contains(.running) { return .running }
        return .stopped
    }

    public func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in await self?.streamLoop() }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    public func stop() {
        streamTask?.cancel()
        pollTask?.cancel()
        streamTask = nil
        pollTask = nil
    }

    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
    }

    public func setToken(_ newToken: String?) {
        token = newToken
        status = .connecting
        stop()
        start()
    }

    // MARK: Actions

    public func start(_ name: String) async { await perform(name) { try await $0.start(name) } }
    public func stop(_ name: String) async { await perform(name) { try await $0.stop(name) } }
    public func restart(_ name: String) async { await perform(name) { try await $0.restart(name) } }

    public func reloadConfiguration() async {
        do {
            try await client.reloadConfiguration()
            lastActionError = nil
        } catch {
            lastActionError = String(describing: error)
        }
        await refresh()
    }

    /// Stops every process and the server itself.
    public func shutDown() async throws {
        try await client.stopProject()
    }

    public func clearActionError() {
        lastActionError = nil
    }

    private func perform(_ name: String, _ action: @Sendable (PCClient) async throws -> Void) async {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await action(client)
            lastActionError = nil
        } catch {
            lastActionError = "\(name): \(error)"
        }
        await refresh()
    }

    // MARK: Loops

    private func streamLoop() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                for try await event in client.stateEvents() {
                    status = .connected
                    backoff = .seconds(1)
                    upsert(event.state)
                }
                // The server closed the socket cleanly: it's shutting down, or restarting.
            } catch PCError.unauthorized {
                status = .needsToken
                processes = []
                return
            } catch {
                if Task.isCancelled { return }
                status = .unreachable(String(describing: error))
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(10))
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            if status != .needsToken {
                await refresh(includePorts: pollTick % 5 == 0)
                pollTick += 1
            }
            try? await Task.sleep(for: visible ? .seconds(2) : .seconds(10))
        }
    }

    public func refresh(includePorts: Bool = true) async {
        let client = self.client
        do {
            async let fetchedProcesses = client.processes()
            async let fetchedProject = client.projectState()
            let (list, project) = try await (fetchedProcesses, fetchedProject)
            self.project = project
            replaceAll(list)
            if status != .connected { status = .connected }
        } catch PCError.unauthorized {
            status = .needsToken
            return
        } catch {
            if case .connected = status { status = .unreachable(String(describing: error)) }
            return
        }
        guard includePorts else { return }
        var newPorts: [String: [Int]] = [:]
        await withTaskGroup(of: (String, [Int]).self) { group in
            for process in processes where process.isRunning {
                group.addTask { (process.name, (try? await client.ports(process.name).tcpPorts) ?? []) }
            }
            for await (name, tcp) in group where !tcp.isEmpty {
                newPorts[name] = tcp.sorted()
            }
        }
        if newPorts != ports { ports = newPorts }
    }

    private func upsert(_ state: ProcessState) {
        if let index = processes.firstIndex(where: { $0.name == state.name }) {
            if processes[index] != state { processes[index] = state }
        } else {
            processes.append(state)
            processes.sort(by: Self.order)
        }
        if !state.isRunning, ports[state.name] != nil { ports[state.name] = nil }
    }

    private func replaceAll(_ list: [ProcessState]) {
        let sorted = list.sorted(by: Self.order)
        if sorted != processes { processes = sorted }
    }

    private static func order(_ a: ProcessState, _ b: ProcessState) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// The name shown for a server no registered project claims: the `name:` from its config
    /// when it set one, else its working directory's folder name (process-compose's default
    /// project name is `<hostname>/<folder>`, which isn't useful in a list).
    public var displayName: String {
        if let name = project?.projectName, !name.isEmpty, !name.contains("/") { return name }
        if let cwd = invocation?.workingDirectory { return (cwd as NSString).lastPathComponent }
        if let name = project?.projectName.split(separator: "/").last { return String(name) }
        return endpoint.description
    }
}
