import Foundation

/// Starts a registered project as a detached, headless process-compose server on a socket
/// Hearth owns, so it outlives Hearth and a relaunched Hearth finds it again by socket path.
public struct Launcher: Sendable {
    public let binary: String
    public let runner: ProcessRunning
    public let environment: [String: String]

    public init(binary: String, runner: ProcessRunning = SubprocessRunner(), environment: [String: String]) {
        self.binary = binary
        self.runner = runner
        self.environment = environment
    }

    /// `$TMPDIR/hearth/`: short enough for the 104-byte `sun_path` limit (a socket under
    /// `~/Library/Application Support/...` can exceed it for long usernames), and cleared on
    /// reboot along with the processes it pointed to.
    public static var socketDirectory: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("hearth")
    }

    public static func socketPath(projectID: String) -> String {
        (socketDirectory as NSString).appendingPathComponent("\(projectID).sock")
    }

    /// The project id when `endpoint` is a socket Hearth itself launched.
    public static func ownedProjectID(for endpoint: Endpoint) -> String? {
        guard case .unix(let path) = endpoint,
              (path as NSString).deletingLastPathComponent == (socketDirectory as NSString).standardizingPath
                || (path as NSString).deletingLastPathComponent == socketDirectory
        else { return nil }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public static var logDirectory: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hearth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func logFile(projectID: String) -> URL {
        logDirectory.appendingPathComponent("\(projectID).log")
    }

    public static func arguments(for project: ProjectContext) -> [String] {
        var args = ["up", "--detached", "--tui=false", "--unix-socket", socketPath(projectID: project.id)]
        for file in project.configFiles { args += ["-f", file] }
        for file in project.envFiles { args += ["-e", file] }
        for namespace in project.namespaces { args += ["-n", namespace] }
        args += ["-L", logFile(projectID: project.id).path]
        return args
    }

    /// Runs `process-compose up --detached`, which itself waits for the server to come up and
    /// fails (non-zero, message on stderr) if it doesn't within 5s.
    @discardableResult
    public func up(_ project: ProjectContext) async throws -> Endpoint {
        try FileManager.default.createDirectory(atPath: Self.socketDirectory, withIntermediateDirectories: true)
        let socket = Self.socketPath(projectID: project.id)
        // A socket file left behind by a crashed server makes the new one fail to bind.
        if FileManager.default.fileExists(atPath: socket), (try? await PCClient(endpoint: .unix(path: socket)).live()) == nil {
            try? FileManager.default.removeItem(atPath: socket)
        }
        let result = try await runner.run(
            executable: binary,
            arguments: Self.arguments(for: project),
            currentDirectory: project.directory,
            environment: environment
        )
        guard result.succeeded else {
            var message = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "process-compose exited with \(result.exitCode)"
            if let tail = Self.logTail(projectID: project.id) {
                message += "\n\n" + tail
            }
            throw PCError.unreachable(message)
        }
        return .unix(path: socket)
    }

    /// The last error-looking lines of a project's process-compose log, for failure messages.
    public static func logTail(projectID: String, lines: Int = 8) -> String? {
        guard let text = try? String(contentsOf: logFile(projectID: projectID), encoding: .utf8) else { return nil }
        let stripped = ANSI.strip(text)
        let tail = stripped.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return tail.isEmpty ? nil : tail
    }
}

/// The user's login-shell environment, so processes Hearth launches find the same tools
/// (`node`, `python3`, mise/nvm/asdf shims, …) they'd find from a terminal. An app launched from
/// Finder/Dock only inherits launchd's minimal environment.
public enum ShellEnvironment {
    public static func load(timeout: Duration = .seconds(5)) async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let runner = SubprocessRunner(killGracePeriod: .milliseconds(200))
        let captured: [String: String]? = await withTaskGroup(of: [String: String]?.self) { group in
            group.addTask {
                // -l for the login profile (Homebrew's shellenv, mise activate, …); -i so
                // ~/.zshrc-only setups count too. Markers fence off anything rc files print.
                guard let result = try? await runner.run(
                    executable: shell,
                    arguments: ["-l", "-i", "-c", "echo __HEARTH_ENV__; /usr/bin/env; echo __HEARTH_END__"],
                    currentDirectory: nil,
                    environment: base
                ) else { return nil }
                return parseEnv(result.stdout)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        var merged = base
        for (key, value) in captured ?? [:] where !["PWD", "OLDPWD", "SHLVL", "_", "TERM"].contains(key) {
            merged[key] = value
        }
        return merged
    }

    static func parseEnv(_ output: String) -> [String: String]? {
        guard let start = output.range(of: "__HEARTH_ENV__\n"),
              let end = output.range(of: "__HEARTH_END__", range: start.upperBound..<output.endIndex) else { return nil }
        var env: [String: String] = [:]
        for line in output[start.upperBound..<end.lowerBound].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = line[..<eq]
            // Multi-line values continue on lines without '='-prefixed identifiers; skip them.
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[String(key)] = String(line[line.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}

public enum ANSI {
    // Chatty dev-server processes (vite, webpack, ...) color their own output for a terminal;
    // rendered as plain Text these CSI codes show up as literal garbage ("[32m[1mVITE[22m").
    private static let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[a-zA-Z]|\u{1B}\\][^\u{07}]*\u{07}")

    public static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
