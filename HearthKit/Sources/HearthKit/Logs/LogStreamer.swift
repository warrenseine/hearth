import Foundation
import Observation

public struct LogLine: Sendable, Identifiable, Equatable {
    public let id: Int
    public let process: String
    public let text: String
}

/// Follows `/process/logs/ws` for one or more processes into a bounded ring buffer, so leaving
/// a logs view open indefinitely doesn't grow memory without limit. Lines are batched onto the
/// main actor every 100ms rather than one observable mutation per line: a chatty process
/// printing thousands of lines a second would otherwise re-render the view per line.
@MainActor
@Observable
public final class LogStreamer {
    public private(set) var lines: [LogLine] = []
    public private(set) var isStreaming = false
    public private(set) var lastError: String?

    private let maxLines: Int
    private var nextID = 0
    private var pending: [LogLine] = []
    private var task: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    public init(maxLines: Int = 50_000) {
        self.maxLines = maxLines
    }

    public func start(client: PCClient, processes: [String], tail: Int = 1000) {
        stop()
        lines.removeAll()
        pending.removeAll()
        lastError = nil
        guard !processes.isEmpty else { return }
        isStreaming = true
        task = Task { [weak self] in
            // Reconnects when the stream drops (process-compose closes it while a process is
            // restarting); only the first connection replays `tail` lines of history.
            var replay = tail
            while !Task.isCancelled {
                do {
                    for try await message in client.logStream(processes: processes, tail: replay) {
                        self?.receive(message)
                    }
                } catch is CancellationError {
                    break
                } catch PCError.unauthorized {
                    self?.lastError = String(describing: PCError.unauthorized)
                    break
                } catch {
                    if Task.isCancelled { break }
                    self?.lastError = String(describing: error)
                }
                replay = 0
                try? await Task.sleep(for: .seconds(1))
            }
            self?.isStreaming = false
        }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.flush()
            }
        }
    }

    public func stop() {
        task?.cancel()
        flushTask?.cancel()
        task = nil
        flushTask = nil
        flush()
        isStreaming = false
    }

    public func clear() {
        lines.removeAll()
        pending.removeAll()
    }

    func receive(_ message: LogMessage) {
        lastError = nil
        var text = ANSI.strip(message.message)
        if text.hasSuffix("\n") { text.removeLast() }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            pending.append(LogLine(id: nextID, process: message.processName, text: String(line)))
            nextID += 1
        }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
