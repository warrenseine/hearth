import Foundation

/// What a running `process-compose` process's command line, environment and working directory
/// say about the API server it hosts: whether it is a server at all (not a client subcommand like
/// `process list` or `attach`), where it listens, and which config files it loaded.
///
/// Mirrors process-compose v1.122's own flag/env precedence: a flag beats its `PC_*` variable,
/// `-u`/`--unix-socket` (or `PC_SOCKET_PATH`) alone switches to a unix socket, `-U` alone uses
/// `$TMPDIR/process-compose-<pid>.sock`, otherwise TCP on `--address`:`--port`
/// (default `localhost:8080`).
public struct ServerInvocation: Sendable, Equatable {
    public let pid: Int32
    public let endpoint: Endpoint
    /// Absolute paths of the `-f` files (relative ones resolved against the process's cwd).
    public let configFiles: [String]
    public let envFiles: [String]
    public let workingDirectory: String?
    /// The API token, when the server was given one through `PC_API_TOKEN` in its environment
    /// or a `--token-file`/`PC_API_TOKEN_PATH` we can read. Same user, same access its own CLI has.
    public let token: String?
    public let tokenRequired: Bool

    /// Flags that consume the following argument as their value (everything else is boolean).
    static let valueFlags: Set<String> = [
        "-f", "--config", "-e", "--env", "-L", "--log-file", "-n", "--namespace", "-p", "--port",
        "-u", "--unix-socket", "--address", "-a", "-r", "--ref-rate", "-S", "--sort",
        "--shortcuts", "--slow-ref-rate", "--theme", "--token-file",
    ]

    /// Subcommands that run the orchestrator (and its API server). Anything else (`process`,
    /// `project`, `attach`, `down`, `list`, `info`, `graph`, `version`, …) is a short-lived client.
    static let serverSubcommands: Set<String?> = [nil, "up", "run"]

    /// Parses one process. Returns `nil` for anything that isn't a process-compose server.
    /// `argv[0]` is the executable as invoked; `readFile` is injectable for tests.
    public static func parse(
        pid: Int32,
        argv: [String],
        environment: [String: String],
        workingDirectory: String?,
        temporaryDirectory: String,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> ServerInvocation? {
        guard let executable = argv.first, (executable as NSString).lastPathComponent == "process-compose" else {
            return nil
        }

        var flags: [String: [String]] = [:]
        var bools: Set<String> = []
        var subcommand: String?
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            index += 1
            if arg.hasPrefix("-") {
                if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") || arg.count > 2 {
                    let name = String(arg[..<eq])
                    let value = String(arg[arg.index(after: eq)...])
                    if valueFlags.contains(name) {
                        flags[name, default: []].append(value)
                    } else if value != "false" {
                        bools.insert(name)
                    }
                } else if valueFlags.contains(arg), index < argv.count {
                    flags[arg, default: []].append(argv[index])
                    index += 1
                } else {
                    bools.insert(arg)
                }
            } else if subcommand == nil {
                subcommand = arg
                // `run PROCESS`/`up PROC...` take process names as positionals; stop at the first.
            }
        }
        guard serverSubcommands.contains(subcommand) else { return nil }

        func value(_ short: String?, _ long: String, env: String?) -> String? {
            let fromFlag = [short, long].compactMap { $0 }.compactMap { flags[$0]?.last }.last
            return fromFlag ?? env.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func isTrue(_ short: String?, _ long: String, env: String?) -> Bool {
            if [short, long].compactMap({ $0 }).contains(where: bools.contains) { return true }
            guard let env, let raw = environment[env] else { return false }
            return ["1", "true", "yes"].contains(raw.lowercased())
        }

        if isTrue(nil, "--no-server", env: "PC_NO_SERVER") { return nil }

        func resolve(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
            guard let workingDirectory else { return expanded }
            return ((workingDirectory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }

        let endpoint: Endpoint
        if let socket = value("-u", "--unix-socket", env: "PC_SOCKET_PATH") {
            endpoint = .unix(path: resolve(socket))
        } else if isTrue("-U", "--use-uds", env: nil) {
            endpoint = .unix(path: (temporaryDirectory as NSString).appendingPathComponent("process-compose-\(pid).sock"))
        } else {
            let port = value("-p", "--port", env: "PC_PORT_NUM").flatMap(Int.init) ?? 8080
            var host = value(nil, "--address", env: "PC_ADDRESS") ?? "localhost"
            if host == "0.0.0.0" || host.isEmpty { host = "localhost" }
            endpoint = .tcp(host: host, port: port)
        }

        var configFiles = (flags["-f"] ?? []) + (flags["--config"] ?? [])
        if configFiles.isEmpty, let fromEnv = environment["PC_CONFIG_FILES"], !fromEnv.isEmpty {
            configFiles = fromEnv.split(separator: ",").map(String.init)
        }
        let envFiles = (flags["-e"] ?? []) + (flags["--env"] ?? [])

        var token = environment["PC_API_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        let tokenPath = value(nil, "--token-file", env: "PC_API_TOKEN_PATH")
        if token == nil, let tokenPath {
            token = readFile(resolve(tokenPath))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ServerInvocation(
            pid: pid,
            endpoint: endpoint,
            configFiles: configFiles.map(resolve),
            envFiles: envFiles.map(resolve),
            workingDirectory: workingDirectory,
            token: token,
            tokenRequired: token != nil || tokenPath != nil
        )
    }
}
