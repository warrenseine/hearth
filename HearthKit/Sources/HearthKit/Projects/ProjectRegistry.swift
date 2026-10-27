import Foundation

/// A project folder the user added. Tracked by a file-system bookmark (not security-scoped —
/// the app is unsandboxed — but still resilient to the folder being renamed or moved on the same
/// volume) rather than a raw path.
public struct RegisteredProject: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// Stable short id; also names the project's socket when Hearth launches it, which is how a
    /// relaunched Hearth recognizes its own still-running instances.
    public let id: String
    public var name: String
    public var bookmarkData: Data
    /// Config files relative to the project folder, in `-f` order.
    public var configFiles: [String]
    public var envFiles: [String]
    /// `-n` namespaces to run; empty means all.
    public var namespaces: [String]
    public var lastSeen: Date
    /// The folder path as of the last successful resolve, for matching discovered servers
    /// without resolving every bookmark on every scan.
    public var lastKnownPath: String?

    /// True once `ProjectRegistry.resolve` fails to turn the bookmark back into a URL — the
    /// folder was deleted, or moved to a different volume.
    public var isOrphaned: Bool = false

    public init(
        id: String = RegisteredProject.makeID(),
        name: String,
        bookmarkData: Data,
        configFiles: [String],
        envFiles: [String] = [],
        namespaces: [String] = [],
        lastSeen: Date = Date(),
        lastKnownPath: String? = nil,
        isOrphaned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.configFiles = configFiles
        self.envFiles = envFiles
        self.namespaces = namespaces
        self.lastSeen = lastSeen
        self.lastKnownPath = lastKnownPath
        self.isOrphaned = isOrphaned
    }

    public static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// Absolute config file paths as of the last resolve.
    public var configFilePaths: [String] {
        guard let lastKnownPath else { return [] }
        return configFiles.map { ((lastKnownPath as NSString).appendingPathComponent($0) as NSString).standardizingPath }
    }
}

/// A registered project resolved to a live folder, ready to launch.
public struct ProjectContext: Sendable, Equatable {
    public let id: String
    public let name: String
    public let directory: URL
    public let configFiles: [String]
    public let envFiles: [String]
    public let namespaces: [String]

    public init(id: String, name: String, directory: URL, configFiles: [String], envFiles: [String] = [], namespaces: [String] = []) {
        self.id = id
        self.name = name
        self.directory = directory
        self.configFiles = configFiles
        self.envFiles = envFiles
        self.namespaces = namespaces
    }
}

private struct ProjectRegistryFile: Codable {
    var projects: [RegisteredProject]
}

public enum ProjectRegistryError: Error, Sendable, CustomStringConvertible {
    case noConfigFileFound(URL)
    case bookmarkCreationFailed(URL, underlying: String)

    public var description: String {
        switch self {
        case .noConfigFileFound(let url):
            return "no process-compose.yaml/.yml found in \(url.path)"
        case .bookmarkCreationFailed(let url, let underlying):
            return "could not bookmark \(url.path): \(underlying)"
        }
    }
}

/// Persists registered project folders to `~/Library/Application Support/Hearth/projects.json`.
public actor ProjectRegistry {
    private let storeURL: URL
    private let fileManager: FileManager
    private var projects: [String: RegisteredProject] = [:]

    public init(storeURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.storeURL = storeURL ?? Self.defaultStoreURL(fileManager: fileManager)
        // Loading is a plain (non-isolated) static function rather than an instance method: an
        // actor's synchronous init cannot call its own isolated methods.
        self.projects = try Self.loadProjects(from: self.storeURL, fileManager: fileManager)
    }

    public static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("Hearth", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }

    /// process-compose's own default discovery: the first of these that exists is the main
    /// file, and its sibling `*.override.*` is merged in automatically if present.
    public static func discoverConfigFiles(in directory: URL, fileManager: FileManager = .default) -> [String] {
        let candidates = ["compose.yml", "compose.yaml", "process-compose.yml", "process-compose.yaml"]
        guard let main = candidates.first(where: { name in
            let path = directory.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path) else { return false }
            // A plain compose.yaml is far more likely to be a Docker Compose file; only take it
            // when it actually declares `processes:`.
            if name.hasPrefix("compose.") {
                return (try? String(contentsOfFile: path, encoding: .utf8))?
                    .split(separator: "\n").contains { $0.hasPrefix("processes:") } ?? false
            }
            return true
        }) else {
            return []
        }
        var files = [main]
        let base = (main as NSString).deletingPathExtension
        let ext = (main as NSString).pathExtension
        let overrideName = "\(base).override.\(ext)"
        if fileManager.fileExists(atPath: directory.appendingPathComponent(overrideName).path) {
            files.append(overrideName)
        }
        return files
    }

    // MARK: Registration

    @discardableResult
    public func register(directory: URL, name: String? = nil, configFiles: [String]? = nil, envFiles: [String] = [], namespaces: [String] = []) throws -> RegisteredProject {
        let resolvedConfigFiles = try configFiles ?? {
            let discovered = Self.discoverConfigFiles(in: directory, fileManager: fileManager)
            guard !discovered.isEmpty else { throw ProjectRegistryError.noConfigFileFound(directory) }
            return discovered
        }()
        let bookmark: Data
        do {
            bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw ProjectRegistryError.bookmarkCreationFailed(directory, underlying: String(describing: error))
        }
        // Re-adding the same folder updates the existing entry (and keeps its id, so a running
        // instance stays matched) instead of creating a duplicate.
        let path = directory.standardizedFileURL.path
        let existing = projects.values.first { $0.lastKnownPath == path }
        let entry = RegisteredProject(
            id: existing?.id ?? RegisteredProject.makeID(),
            name: name ?? existing?.name ?? directory.lastPathComponent,
            bookmarkData: bookmark,
            configFiles: resolvedConfigFiles,
            envFiles: envFiles,
            namespaces: namespaces,
            lastSeen: Date(),
            lastKnownPath: path,
            isOrphaned: false
        )
        projects[entry.id] = entry
        try persist()
        return entry
    }

    public func unregister(id: String) throws {
        projects.removeValue(forKey: id)
        try persist()
    }

    @discardableResult
    public func update(id: String, _ change: (inout RegisteredProject) -> Void) throws -> RegisteredProject? {
        guard var entry = projects[id] else { return nil }
        change(&entry)
        projects[id] = entry
        try persist()
        return entry
    }

    public func all() -> [RegisteredProject] {
        Array(projects.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func entry(id: String) -> RegisteredProject? { projects[id] }

    /// Resolves a registered project's bookmark back into a live `ProjectContext`. Returns `nil`
    /// (and flags the entry as orphaned) if the folder can no longer be found.
    public func resolve(id: String) -> ProjectContext? {
        guard var entry = projects[id] else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale),
              fileManager.fileExists(atPath: url.path) else {
            entry.isOrphaned = true
            projects[id] = entry
            try? persist()
            return nil
        }
        if isStale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            entry.bookmarkData = refreshed
        }
        entry.isOrphaned = false
        entry.lastSeen = Date()
        entry.lastKnownPath = url.standardizedFileURL.path
        projects[id] = entry
        try? persist()
        return ProjectContext(id: id, name: entry.name, directory: url, configFiles: entry.configFiles, envFiles: entry.envFiles, namespaces: entry.namespaces)
    }

    /// Re-resolves every bookmark, refreshing `lastKnownPath` and `isOrphaned`.
    public func refreshAll() -> [RegisteredProject] {
        for id in projects.keys { _ = resolve(id: id) }
        return all()
    }

    // MARK: Persistence

    private static func loadProjects(from storeURL: URL, fileManager: FileManager) throws -> [String: RegisteredProject] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [:] }
        let data = try Data(contentsOf: storeURL)
        let decoded = try JSONDecoder().decode(ProjectRegistryFile.self, from: data)
        return Dictionary(decoded.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() throws {
        let file = ProjectRegistryFile(projects: all())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: storeURL, options: .atomic)
    }
}
