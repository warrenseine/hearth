import Foundation

/// One process as reported by `GET /processes`, `GET /process/{name}` and the states WebSocket.
///
/// Every field past `name` decodes leniently (missing → a neutral default): the swagger spec
/// doesn't mark which fields are always present, and state events for a process that hasn't
/// started yet were observed to omit e.g. `last_activity_time`. A strict decode failure here
/// would blank the whole process table over one absent key.
public struct ProcessState: Sendable, Equatable, Identifiable, Decodable {
    public var id: String { name }
    public let name: String
    public let namespace: String
    public let status: String
    public let systemTime: String
    /// Nanoseconds since the process (re)started; 0 while not running.
    public let age: Int64
    /// `"Ready"`, `"Not Ready"`, or `"-"` when the process has no readiness probe.
    public let isReady: String
    public let hasReadyProbe: Bool
    public let restarts: Int
    public let exitCode: Int
    public let pid: Int
    public let isRunning: Bool
    /// Resident memory in bytes.
    public let mem: Int64
    public let cpu: Double
    public let processStartTime: Date?
    public let processReadyTime: Date?
    public let processEndTime: Date?
    public let lastActivityTime: Date?

    public init(
        name: String,
        namespace: String = "default",
        status: String,
        systemTime: String = "-",
        age: Int64 = 0,
        isReady: String = "-",
        hasReadyProbe: Bool = false,
        restarts: Int = 0,
        exitCode: Int = 0,
        pid: Int = 0,
        isRunning: Bool = false,
        mem: Int64 = 0,
        cpu: Double = 0,
        processStartTime: Date? = nil,
        processReadyTime: Date? = nil,
        processEndTime: Date? = nil,
        lastActivityTime: Date? = nil
    ) {
        self.name = name
        self.namespace = namespace
        self.status = status
        self.systemTime = systemTime
        self.age = age
        self.isReady = isReady
        self.hasReadyProbe = hasReadyProbe
        self.restarts = restarts
        self.exitCode = exitCode
        self.pid = pid
        self.isRunning = isRunning
        self.mem = mem
        self.cpu = cpu
        self.processStartTime = processStartTime
        self.processReadyTime = processReadyTime
        self.processEndTime = processEndTime
        self.lastActivityTime = lastActivityTime
    }

    private enum CodingKeys: String, CodingKey {
        case name, namespace, status, age, restarts, pid, mem, cpu
        case systemTime = "system_time"
        case isReady = "is_ready"
        case hasReadyProbe = "has_ready_probe"
        case exitCode = "exit_code"
        case isRunning = "is_running"
        case processStartTime = "process_start_time"
        case processReadyTime = "process_ready_time"
        case processEndTime = "process_end_time"
        case lastActivityTime = "last_activity_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace) ?? "default"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "Unknown"
        systemTime = try c.decodeIfPresent(String.self, forKey: .systemTime) ?? "-"
        age = try c.decodeIfPresent(Int64.self, forKey: .age) ?? 0
        isReady = try c.decodeIfPresent(String.self, forKey: .isReady) ?? "-"
        hasReadyProbe = try c.decodeIfPresent(Bool.self, forKey: .hasReadyProbe) ?? false
        restarts = try c.decodeIfPresent(Int.self, forKey: .restarts) ?? 0
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        mem = try c.decodeIfPresent(Int64.self, forKey: .mem) ?? 0
        cpu = try c.decodeIfPresent(Double.self, forKey: .cpu) ?? 0
        processStartTime = PCDate.decode(c, .processStartTime)
        processReadyTime = PCDate.decode(c, .processReadyTime)
        processEndTime = PCDate.decode(c, .processEndTime)
        lastActivityTime = PCDate.decode(c, .lastActivityTime)
    }
}

extension ProcessState {
    public enum Health: Sendable, Equatable {
        case ready, notReady, noProbe
    }

    public var health: Health {
        guard hasReadyProbe else { return .noProbe }
        return isReady == "Ready" ? .ready : .notReady
    }

    /// Coarse state used for status dots and the menu bar: process-compose's own `status`
    /// strings (Running, Pending, Launching, Restarting, Completed, Skipped, Disabled, Error,
    /// Foreground, Terminating, Scheduled…) collapsed to what the UI distinguishes.
    public enum Phase: Sendable, Equatable {
        case running, transitioning, stopped, failed
    }

    public var phase: Phase {
        switch status {
        case "Running":
            return hasReadyProbe && isReady != "Ready" ? .transitioning : .running
        case "Launching", "Launched", "Pending", "Restarting", "Terminating", "Foreground":
            return .transitioning
        case "Error":
            return .failed
        case "Completed":
            return exitCode == 0 ? .stopped : .failed
        default:
            return .stopped
        }
    }

    /// Whether a Start action makes sense. process-compose refuses to start a process that is
    /// still running ("process is already running"), and `is_running` already reads false while
    /// it is terminating or about to restart, so those states are excluded too.
    public var canStart: Bool {
        !isRunning && !["Restarting", "Terminating", "Launching", "Launched", "Pending"].contains(status)
    }
}

/// `GET /project/state`.
public struct ProjectState: Sendable, Equatable, Decodable {
    public let projectName: String
    public let version: String
    public let userName: String
    public let startTime: Date?
    /// Nanoseconds.
    public let upTime: Int64
    public let processNum: Int
    public let runningProcessNum: Int
    public let fileNames: [String]

    public init(
        projectName: String,
        version: String = "",
        userName: String = "",
        startTime: Date? = nil,
        upTime: Int64 = 0,
        processNum: Int = 0,
        runningProcessNum: Int = 0,
        fileNames: [String] = []
    ) {
        self.projectName = projectName
        self.version = version
        self.userName = userName
        self.startTime = startTime
        self.upTime = upTime
        self.processNum = processNum
        self.runningProcessNum = runningProcessNum
        self.fileNames = fileNames
    }

    private enum CodingKeys: String, CodingKey {
        case projectName, version, userName, startTime, upTime, processNum, runningProcessNum, fileNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
        startTime = PCDate.decode(c, .startTime)
        upTime = try c.decodeIfPresent(Int64.self, forKey: .upTime) ?? 0
        processNum = try c.decodeIfPresent(Int.self, forKey: .processNum) ?? 0
        runningProcessNum = try c.decodeIfPresent(Int.self, forKey: .runningProcessNum) ?? 0
        fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames) ?? []
    }
}

/// `GET /process/ports/{name}`.
public struct ProcessPorts: Sendable, Equatable, Decodable {
    public let name: String
    public let tcpPorts: [Int]
    public let udpPorts: [Int]

    public init(name: String, tcpPorts: [Int], udpPorts: [Int] = []) {
        self.name = name
        self.tcpPorts = tcpPorts
        self.udpPorts = udpPorts
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case tcpPorts = "tcp_ports"
        case udpPorts = "udp_ports"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        tcpPorts = try c.decodeIfPresent([Int].self, forKey: .tcpPorts) ?? []
        udpPorts = try c.decodeIfPresent([Int].self, forKey: .udpPorts) ?? []
    }
}

/// `GET /process/info/{name}`: the resolved process config. Only the fields the UI calls out
/// are typed; the whole payload is also kept pretty-printed for the raw config view.
public struct ProcessConfig: Sendable, Equatable {
    public let name: String
    public let command: String?
    public let workingDir: String?
    public let namespace: String?
    public let replicas: Int?
    public let prettyJSON: String

    public init(data: Data) throws {
        struct Typed: Decodable {
            let name: String
            let command: String?
            let workingDir: String?
            let namespace: String?
            let replicas: Int?
        }
        let typed = try JSONDecoder().decode(Typed.self, from: data)
        name = typed.name
        command = typed.command
        workingDir = typed.workingDir
        namespace = typed.namespace
        replicas = typed.replicas
        // `originalConfig` is the same config again as an escaped JSON string; dropping it keeps
        // the raw view readable.
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "originalConfig")
        let pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        prettyJSON = pretty ?? String(decoding: data, as: UTF8.self)
    }
}

/// One frame from `GET /process/logs/ws`.
public struct LogMessage: Sendable, Equatable, Decodable {
    public let message: String
    public let processName: String

    public init(message: String, processName: String) {
        self.message = message
        self.processName = processName
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case processName = "process_name"
    }
}

/// One frame from `GET /process/states/ws`: an initial `snapshot: true` frame per process on
/// connect, then one frame per status/health transition.
public struct ProcessStateEvent: Sendable, Equatable, Decodable {
    public let snapshot: Bool
    public let state: ProcessState

    private enum CodingKeys: String, CodingKey { case snapshot, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try c.decodeIfPresent(Bool.self, forKey: .snapshot) ?? false
        state = try c.decode(ProcessState.self, forKey: .state)
    }
}

struct ProcessesEnvelope: Decodable {
    let data: [ProcessState]
}

struct ErrorEnvelope: Decodable {
    let error: String
}

/// process-compose emits Go `time.Time` RFC 3339 timestamps with a variable number of
/// fractional digits (`…07.133659+01:00`, `…07.13386+01:00`) and the zero time
/// (`0001-01-01T00:00:00Z`) for "never". Neither `JSONDecoder.DateDecodingStrategy.iso8601`
/// (no fractions at all) nor a fixed-format formatter handles both, so dates decode by hand.
enum PCDate {
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return parse(raw)
    }

    // ISO8601DateFormatter is documented thread-safe since macOS 10.12, just not marked Sendable.
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        if raw.isEmpty || raw.hasPrefix("0001-01-01") { return nil }
        // Normalize the fraction to exactly 3 digits (milliseconds), which the formatter accepts.
        if let dot = raw.firstIndex(of: "."), raw[raw.index(after: dot)...].first?.isNumber == true {
            let digitsStart = raw.index(after: dot)
            let digitsEnd = raw[digitsStart...].firstIndex(where: { !$0.isNumber }) ?? raw.endIndex
            var digits = String(raw[digitsStart..<digitsEnd].prefix(3))
            while digits.count < 3 { digits += "0" }
            let normalized = raw[..<digitsStart] + digits + raw[digitsEnd...]
            return withFraction.date(from: String(normalized))
        }
        return withoutFraction.date(from: raw)
    }
}
