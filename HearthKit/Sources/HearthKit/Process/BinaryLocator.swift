import Foundation

/// Finds the `process-compose` binary, in a well-defined precedence: explicit override (the
/// Settings field, or `HEARTH_PROCESS_COMPOSE_BIN`) > common install locations > `PATH`.
///
/// The common locations matter more than `PATH` here: a GUI app launched from Finder/Dock gets
/// launchd's minimal `PATH`, which has none of Homebrew, `~/.local/bin` (the upstream install
/// script's default), mise, or Nix.
public struct BinaryLocator: Sendable {
    public static let overrideEnv = "HEARTH_PROCESS_COMPOSE_BIN"

    private let environment: [String: String]
    private let override: String?
    // FileManager isn't Sendable, but `.default` (the only instance ever passed here in practice)
    // is documented as safe to use concurrently for the read-only checks this type performs.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) {
        self.override = override
        self.environment = environment
        self.fileManager = fileManager
    }

    private var commonPaths: [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.nix-profile/bin",
            "/run/current-system/sw/bin",
            "\(home)/go/bin",
        ]
    }

    public func locateProcessCompose() -> String? {
        for candidate in [override, environment[Self.overrideEnv]].compactMap({ $0 }) where !candidate.isEmpty {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) { return expanded }
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in commonPaths + pathDirs {
            let candidate = dir + "/process-compose"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
