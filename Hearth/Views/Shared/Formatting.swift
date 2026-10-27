import Foundation

enum Formatting {
    static func bytes(_ value: Int64) -> String {
        value > 0 ? ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) : "—"
    }

    static func cpu(_ value: Double, running: Bool) -> String {
        running ? String(format: "%.1f%%", value) : "—"
    }

    /// process-compose reports ages/uptimes as Go `time.Duration` nanoseconds.
    static func duration(nanoseconds: Int64) -> String {
        guard nanoseconds > 0 else { return "—" }
        return duration(seconds: Int(nanoseconds / 1_000_000_000))
    }

    static func duration(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        return duration(seconds: max(0, Int(now.timeIntervalSince(date))))
    }

    static func duration(seconds: Int) -> String {
        let (d, h, m, s) = (seconds / 86_400, (seconds % 86_400) / 3600, (seconds % 3600) / 60, seconds % 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
