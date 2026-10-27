import Darwin
import Foundation

/// Reads the exact argv, environment and cwd of the current user's processes through libproc
/// and `sysctl(KERN_PROCARGS2)`, rather than parsing `ps` text: `ps`'s args column is argv
/// space-joined, so a socket under "Application Support" (or any path with a space) can't be
/// split back apart reliably, and `ps` doesn't show the environment at all.
public enum ProcessTable {
    public struct Entry: Sendable, Equatable {
        public let pid: Int32
        public let argv: [String]
        public let environment: [String: String]
        public let workingDirectory: String?
    }

    /// Every process whose executable is named `process-compose`. Other users' processes are
    /// skipped (the kernel refuses KERN_PROCARGS2 for them anyway).
    public static func processComposeProcesses() -> [Entry] {
        allPIDs().compactMap { pid in
            guard executableName(pid) == "process-compose", let (argv, env) = arguments(pid) else { return nil }
            return Entry(pid: pid, argv: argv, environment: env, workingDirectory: workingDirectory(pid))
        }
    }

    static func allPIDs() -> [Int32] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Headroom for processes spawned between the sizing call and the real one.
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    static func executableName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).lastPathComponent
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    /// argv and envp from KERN_PROCARGS2, whose layout is: `int argc`, the exec path, NUL
    /// padding, then argc NUL-terminated argv strings, then NUL-terminated `KEY=VALUE` env strings.
    static func arguments(_ pid: Int32) -> (argv: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ bytes: [UInt8]) -> (argv: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = 4
        // Skip the exec path, then the NUL padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        var argv: [String] = []
        for _ in 0..<max(0, Int(argc)) {
            guard let arg = nextString() else { break }
            argv.append(arg)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (argv, environment)
    }
}

/// Finds every reachable-looking process-compose API server on this machine.
public struct Discovery: Sendable {
    public var temporaryDirectory: String
    public var listProcesses: @Sendable () -> [ProcessTable.Entry]

    public init(
        temporaryDirectory: String = NSTemporaryDirectory(),
        listProcesses: @escaping @Sendable () -> [ProcessTable.Entry] = ProcessTable.processComposeProcesses
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.listProcesses = listProcesses
    }

    public func scan() -> [ServerInvocation] {
        var seen = Set<Endpoint>()
        return listProcesses()
            .compactMap {
                ServerInvocation.parse(
                    pid: $0.pid,
                    argv: $0.argv,
                    environment: $0.environment,
                    workingDirectory: $0.workingDirectory,
                    temporaryDirectory: temporaryDirectory
                )
            }
            // `process-compose up -D` forks: for a moment parent and daemon both match.
            .sorted { $0.pid < $1.pid }
            .filter { seen.insert($0.endpoint).inserted }
    }
}
