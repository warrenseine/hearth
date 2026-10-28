import Foundation
import Observation

/// One row of the project list: a registered project (running or not), a discovered server no
/// registered project claims, or both joined.
@MainActor
public struct ProjectEntry: Identifiable, Equatable {
    public let id: String
    public let project: RegisteredProject?
    public let connection: ServerConnection?

    public var title: String {
        project?.name ?? connection?.displayName ?? id
    }

    /// Hearth launched this server (on its own socket) and owns its lifecycle.
    public var isOwned: Bool {
        guard let connection else { return false }
        return Launcher.ownedProjectID(for: connection.endpoint) != nil
    }

    public var isRunning: Bool { connection != nil }

    /// The project's folder, or the discovered server's working directory.
    public var directory: String? {
        project?.lastKnownPath ?? connection?.invocation?.workingDirectory
    }

    public nonisolated static func == (lhs: ProjectEntry, rhs: ProjectEntry) -> Bool {
        lhs.id == rhs.id && lhs.project == rhs.project && lhs.connection === rhs.connection
    }
}

/// The app's model: registered projects, the servers discovery finds, and the join of the two.
@MainActor
@Observable
public final class HearthStore {
    public private(set) var projects: [RegisteredProject] = []
    public private(set) var connections: [Endpoint: ServerConnection] = [:]
    /// Project ids with an `up`/`down` in flight.
    public private(set) var pending: Set<String> = []
    public var lastError: String?
    public private(set) var binaryPath: String?
    /// Latest PR for each entry's checked-out branch, by folder. Looked up when a folder first
    /// appears and again on `refreshPullRequests()` (the menu bar calls it when it opens).
    public private(set) var pullRequests: [String: PullRequest] = [:]

    public let registry: ProjectRegistry
    private let discovery: Discovery
    private var binaryOverride: String?
    private var shellEnvironment: [String: String]?
    private var visible = true
    private var scanTask: Task<Void, Never>?
    private let pullRequestLookup: PullRequestLookup?
    private var pullRequestFolders: Set<String> = []

    public init(registry: ProjectRegistry, discovery: Discovery = Discovery(), binaryOverride: String? = nil, pullRequestLookup: PullRequestLookup? = .located()) {
        self.registry = registry
        self.discovery = discovery
        self.binaryOverride = binaryOverride
        self.pullRequestLookup = pullRequestLookup
        binaryPath = BinaryLocator(override: binaryOverride).locateProcessCompose()
    }

    // MARK: Derived

    public var entries: [ProjectEntry] {
        var claimed = Set<Endpoint>()
        var result: [ProjectEntry] = projects.map { project in
            let connection = connection(for: project)
            if let connection { claimed.insert(connection.endpoint) }
            return ProjectEntry(id: "project:\(project.id)", project: project, connection: connection)
        }
        let unclaimed = connections.values
            .filter { !claimed.contains($0.endpoint) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        result += unclaimed.map { ProjectEntry(id: "server:\($0.endpoint.description)", project: nil, connection: $0) }
        return result
    }

    public func entry(id: String) -> ProjectEntry? {
        entries.first { $0.id == id }
    }

    /// The running server for a registered project: the one on its owned socket, else one whose
    /// config files match (started from a terminal in that folder).
    public func connection(for project: RegisteredProject) -> ServerConnection? {
        if let owned = connections[.unix(path: Launcher.socketPath(projectID: project.id))] { return owned }
        let wanted = Set(project.configFilePaths.map(Self.canonical))
        guard !wanted.isEmpty else { return nil }
        return connections.values
            .filter { Launcher.ownedProjectID(for: $0.endpoint) == nil }
            .first { connection in
                guard let files = connection.invocation?.configFiles else { return false }
                if !files.isEmpty { return !wanted.isDisjoint(with: files.map(Self.canonical)) }
                // No -f: process-compose used its default discovery in its cwd.
                guard let cwd = connection.invocation?.workingDirectory, let folder = project.lastKnownPath else { return false }
                return Self.canonical(cwd) == Self.canonical(folder)
            }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Lifecycle

    public func start() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.reloadProjects()
            while !Task.isCancelled {
                await self?.rescan()
                let interval: Duration = (self?.visible ?? true) ? .seconds(3) : .seconds(15)
                try? await Task.sleep(for: interval)
            }
        }
        Task { shellEnvironment = await ShellEnvironment.load() }
    }

    public func stop() {
        scanTask?.cancel()
        scanTask = nil
        connections.values.forEach { $0.stop() }
    }

    public func setVisible(_ isVisible: Bool) {
        visible = isVisible
        connections.values.forEach { $0.setVisible(isVisible) }
    }

    public func setBinaryOverride(_ path: String?) {
        binaryOverride = path
        binaryPath = BinaryLocator(override: path).locateProcessCompose()
    }

    public func reloadProjects() async {
        projects = await registry.refreshAll()
        Task { await refreshPullRequests(onlyNew: true) }
    }

    /// Reconciles `connections` with what discovery sees right now.
    public func rescan() async {
        let discovery = self.discovery
        let found = await Task.detached { discovery.scan() }.value
        let foundByEndpoint = Dictionary(found.map { ($0.endpoint, $0) }, uniquingKeysWith: { first, _ in first })

        for (endpoint, connection) in connections where foundByEndpoint[endpoint] == nil {
            connection.stop()
            connections[endpoint] = nil
        }
        for (endpoint, invocation) in foundByEndpoint {
            if let existing = connections[endpoint] {
                existing.invocation = invocation
                continue
            }
            let connection = ServerConnection(
                endpoint: endpoint,
                invocation: invocation,
                token: invocation.token ?? TokenStore.token(for: endpoint)
            )
            connection.setVisible(visible)
            connections[endpoint] = connection
            connection.start()
        }
        Task { await refreshPullRequests(onlyNew: true) }
    }

    // MARK: Pull requests

    public func pullRequest(for entry: ProjectEntry) -> PullRequest? {
        entry.directory.flatMap { pullRequests[$0] }
    }

    /// Re-resolves every entry's PR (`onlyNew`: just folders not looked up yet). No-op without `gh`.
    public func refreshPullRequests(onlyNew: Bool = false) async {
        guard let lookup = pullRequestLookup else { return }
        let folders = Set(entries.compactMap(\.directory)).filter { !onlyNew || !pullRequestFolders.contains($0) }
        guard !folders.isEmpty else { return }
        pullRequestFolders.formUnion(folders)
        let found = await withTaskGroup(of: (String, PullRequest?).self) { group in
            for folder in folders {
                group.addTask { (folder, await lookup.pullRequest(in: folder)) }
            }
            var found: [(String, PullRequest?)] = []
            for await result in group { found.append(result) }
            return found
        }
        for (folder, pullRequest) in found {
            pullRequests[folder] = pullRequest
        }
    }

    // MARK: Projects

    @discardableResult
    public func addProject(directory: URL, configFiles: [String]? = nil, envFiles: [String] = [], namespaces: [String] = []) async -> Result<RegisteredProject, Error> {
        do {
            let entry = try await registry.register(directory: directory, configFiles: configFiles, envFiles: envFiles, namespaces: namespaces)
            await reloadProjects()
            return .success(entry)
        } catch {
            return .failure(error)
        }
    }

    public func removeProject(id: String) async {
        try? await registry.unregister(id: id)
        await reloadProjects()
    }

    public func updateProject(id: String, _ change: @Sendable (inout RegisteredProject) -> Void) async {
        _ = try? await registry.update(id: id, change)
        await reloadProjects()
    }

    public func up(_ project: RegisteredProject) async {
        guard let binary = binaryPath else {
            lastError = "process-compose was not found. Install it, or set its path in Settings."
            return
        }
        guard let context = await registry.resolve(id: project.id) else {
            lastError = "The folder for \(project.name) can no longer be found."
            await reloadProjects()
            return
        }
        pending.insert(project.id)
        defer { pending.remove(project.id) }
        var environment = shellEnvironment
        if environment == nil {
            environment = await ShellEnvironment.load()
            shellEnvironment = environment
        }
        do {
            try await Launcher(binary: binary, environment: environment ?? ProcessInfo.processInfo.environment).up(context)
            lastError = nil
        } catch {
            lastError = "Couldn't start \(project.name): \(error)"
        }
        await rescan()
    }

    /// `process-compose down` for any running server: stops its processes and the server.
    public func down(_ entry: ProjectEntry) async {
        guard let connection = entry.connection else { return }
        let key = entry.project?.id ?? entry.id
        pending.insert(key)
        defer { pending.remove(key) }
        do {
            try await connection.shutDown()
            lastError = nil
        } catch {
            lastError = "Couldn't stop \(entry.title): \(error)"
        }
        // The server exits shortly after replying; give discovery a moment to see it gone.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            await rescan()
            if connections[connection.endpoint] == nil { break }
        }
    }

    public func isPending(_ entry: ProjectEntry) -> Bool {
        pending.contains(entry.project?.id ?? entry.id)
    }

    public func setToken(_ token: String?, for connection: ServerConnection) {
        TokenStore.setToken(token, for: connection.endpoint)
        connection.setToken(token)
    }
}
