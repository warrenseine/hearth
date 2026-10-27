import Testing
import Foundation
@testable import HearthKit

@Suite("Discovering process-compose servers from argv/env/cwd")
struct DiscoveryTests {
    private func parse(_ argv: [String], env: [String: String] = [:], cwd: String? = "/work/app", pid: Int32 = 42) -> ServerInvocation? {
        ServerInvocation.parse(pid: pid, argv: argv, environment: env, workingDirectory: cwd, temporaryDirectory: "/tmp/T/", readFile: { $0 == "/work/app/token.txt" ? "file-token-0123456789\n" : nil })
    }

    @Test("a detached worktree stack: -U -u socket, absolute config, trailing up subcommand")
    func worktreeStack() throws {
        let inv = try #require(parse([
            "/Users/dev/.local/share/mise/installs/process-compose/1.122.0/process-compose",
            "-U", "-u", "/Users/dev/Code/app/.stack/pc.sock",
            "-f", "/Users/dev/Code/app/process-compose.yaml", "-e", "/Users/dev/Code/app/.env",
            "--ordered-shutdown", "up", "--tui=false", "-t=false",
        ]))
        #expect(inv.endpoint == .unix(path: "/Users/dev/Code/app/.stack/pc.sock"))
        #expect(inv.configFiles == ["/Users/dev/Code/app/process-compose.yaml"])
        #expect(inv.envFiles == ["/Users/dev/Code/app/.env"])
        #expect(inv.token == nil && !inv.tokenRequired)
    }

    @Test("relative socket and config paths resolve against the process's cwd, with paths containing spaces")
    func relativePaths() throws {
        let inv = try #require(parse(["process-compose", "up", "--unix-socket=run/pc.sock", "-f", "conf/pc.yaml"], cwd: "/Users/dev/Application Support/app"))
        #expect(inv.endpoint == .unix(path: "/Users/dev/Application Support/app/run/pc.sock"))
        #expect(inv.configFiles == ["/Users/dev/Application Support/app/conf/pc.yaml"])
    }

    @Test("-U alone uses the per-pid default socket in TMPDIR")
    func defaultSocket() {
        #expect(parse(["process-compose", "-U"], pid: 777)?.endpoint == .unix(path: "/tmp/T/process-compose-777.sock"))
    }

    @Test("TCP: defaults, -p, PC_PORT_NUM, --address, and 0.0.0.0 mapped to localhost")
    func tcp() {
        #expect(parse(["process-compose"])?.endpoint == .tcp(host: "localhost", port: 8080))
        #expect(parse(["process-compose", "up", "-p", "18099"])?.endpoint == .tcp(host: "localhost", port: 18099))
        #expect(parse(["process-compose"], env: ["PC_PORT_NUM": "9000"])?.endpoint == .tcp(host: "localhost", port: 9000))
        #expect(parse(["process-compose", "--port=9001", "--address", "0.0.0.0"])?.endpoint == .tcp(host: "localhost", port: 9001))
        #expect(parse(["process-compose", "--address", "127.0.0.1"])?.endpoint == .tcp(host: "127.0.0.1", port: 8080))
    }

    @Test("client subcommands, --no-server and other executables are not servers")
    func notServers() {
        #expect(parse(["process-compose", "process", "list", "-u", "/x.sock"]) == nil)
        #expect(parse(["process-compose", "attach", "-p", "18099"]) == nil)
        #expect(parse(["process-compose", "down"]) == nil)
        #expect(parse(["process-compose", "up", "--no-server"]) == nil)
        #expect(parse(["process-compose"], env: ["PC_NO_SERVER": "1"]) == nil)
        #expect(parse(["/usr/bin/vim", "process-compose.yaml"]) == nil)
        // A flag value that happens to equal a client subcommand isn't mistaken for one.
        #expect(parse(["process-compose", "-n", "process", "up"]) != nil)
        #expect(parse(["process-compose", "run", "web"]) != nil)
    }

    @Test("picks up the API token from the server's env or its token file")
    func tokens() {
        #expect(parse(["process-compose"], env: ["PC_API_TOKEN": "env-token-0123456789"])?.token == "env-token-0123456789")
        let fromFile = parse(["process-compose", "--token-file", "token.txt"])
        #expect(fromFile?.token == "file-token-0123456789")
        #expect(fromFile?.tokenRequired == true)
        let unreadable = parse(["process-compose", "--token-file", "/nope"])
        #expect(unreadable?.token == nil)
        #expect(unreadable?.tokenRequired == true)
    }

    @Test("parses the KERN_PROCARGS2 layout")
    func procArgs() throws {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/bin/process-compose".utf8) + [0, 0, 0, 0]
        for arg in ["process-compose", "-u", "/a b/pc.sock"] { bytes += Array(arg.utf8) + [0] }
        for env in ["HOME=/Users/dev", "PC_API_TOKEN=a=b"] { bytes += Array(env.utf8) + [0] }
        bytes += [0, 0]
        let parsed = try #require(ProcessTable.parseProcArgs(bytes))
        #expect(parsed.argv == ["process-compose", "-u", "/a b/pc.sock"])
        #expect(parsed.environment == ["HOME": "/Users/dev", "PC_API_TOKEN": "a=b"])
    }

    @Test("dedupes servers sharing an endpoint, keeping the lowest pid")
    func dedupe() {
        let discovery = Discovery(temporaryDirectory: "/tmp/T/") {
            [
                .init(pid: 20, argv: ["process-compose", "up", "-u", "/s.sock"], environment: [:], workingDirectory: "/"),
                .init(pid: 10, argv: ["process-compose", "up", "-D", "-u", "/s.sock"], environment: [:], workingDirectory: "/"),
                .init(pid: 30, argv: ["process-compose", "process", "list"], environment: [:], workingDirectory: "/"),
            ]
        }
        #expect(discovery.scan().map(\.pid) == [10])
    }

    @Test("recognizes sockets Hearth launched itself")
    func ownedSockets() {
        #expect(Launcher.ownedProjectID(for: .unix(path: Launcher.socketPath(projectID: "ab12cd34"))) == "ab12cd34")
        #expect(Launcher.ownedProjectID(for: .unix(path: "/elsewhere/ab12cd34.sock")) == nil)
        #expect(Launcher.ownedProjectID(for: .tcp(host: "localhost", port: 8080)) == nil)
    }

    @Test("launch arguments put the owned socket, config, env and namespaces on the command line")
    func launchArguments() {
        let project = ProjectContext(id: "ab12cd34", name: "app", directory: URL(fileURLWithPath: "/work/app"), configFiles: ["process-compose.yaml"], envFiles: [".env"], namespaces: ["jobs"])
        let args = Launcher.arguments(for: project)
        #expect(args.starts(with: ["up", "--detached", "--tui=false", "--unix-socket", Launcher.socketPath(projectID: "ab12cd34")]))
        #expect(args.contains("-f") && args.contains("process-compose.yaml"))
        #expect(args.contains("-e") && args.contains(".env"))
        #expect(args.contains("-n") && args.contains("jobs"))
        #expect(Launcher.socketPath(projectID: "ab12cd34").utf8.count < 104)
    }
}

@Suite("Misc helpers")
struct HelperTests {
    @Test("extracts env between markers, ignoring rc-file noise and continuation lines")
    func shellEnv() {
        let output = "welcome!\n__HEARTH_ENV__\nPATH=/opt/homebrew/bin:/usr/bin\nMULTI=line one\nline two\nFOO=a=b\n__HEARTH_END__\n"
        let env = ShellEnvironment.parseEnv(output)
        #expect(env?["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env?["FOO"] == "a=b")
        #expect(env?.count == 3)
        #expect(ShellEnvironment.parseEnv("no markers") == nil)
    }

    @Test("strips CSI and OSC escapes")
    func ansi() {
        #expect(ANSI.strip("\u{1B}[32m\u{1B}[1mVITE\u{1B}[22m ready") == "VITE ready")
        #expect(ANSI.strip("\u{1B}]8;;http://x\u{07}link") == "link")
        #expect(ANSI.strip("plain") == "plain")
    }
}
