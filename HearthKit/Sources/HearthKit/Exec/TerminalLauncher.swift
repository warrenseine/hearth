import Foundation

public enum TerminalApp: String, Sendable, CaseIterable, Codable {
    case terminal = "Terminal"
    case iterm = "iTerm"
}

/// Opens a command in the user's terminal of choice. Used for `process-compose attach`, which
/// gives the full upstream TUI on any server Hearth knows about.
public enum TerminalLauncher {
    public static func attach(endpoint: Endpoint, token: String?, binary: String, directory: String?, app: TerminalApp = .terminal) throws {
        var command = ([binary, "attach"] + endpoint.clientFlags).map(shellQuote).joined(separator: " ")
        if let token { command = "PC_API_TOKEN=\(shellQuote(token)) " + command }
        if let directory { command = "cd \(shellQuote(directory)) && " + command }
        try run(command, in: app)
    }

    public static func run(_ command: String, in app: TerminalApp) throws {
        let script: String
        switch app {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "\(escapeForAppleScript(command))"
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(escapeForAppleScript(command))"
                end tell
            end tell
            """
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
