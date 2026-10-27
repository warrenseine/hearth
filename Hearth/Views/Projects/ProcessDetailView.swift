import SwiftUI
import HearthKit

/// Bottom pane: live logs for the selected process (or all of them), its resolved config, and
/// its timings/ports.
struct ProcessDetailView: View {
    let connection: ServerConnection
    let processName: String?

    enum Tab: String, CaseIterable { case logs = "Logs", config = "Config", info = "Info" }
    @State private var tab: Tab = .logs
    @State private var allProcesses = false

    private var process: ProcessState? {
        connection.processes.first { $0.name == processName }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(tab == .logs && allProcesses ? "all processes" : (processName ?? ""))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if tab == .logs {
                    Toggle("All processes", isOn: $allProcesses).toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .logs:
                LogsView(connection: connection, processes: logTargets)
                    .id(logTargets.joined(separator: ",") + connection.endpoint.description)
            case .config:
                if let processName {
                    ConfigView(connection: connection, processName: processName).id(processName)
                } else {
                    EmptyStateView(systemImage: "gearshape", title: "No process selected")
                }
            case .info:
                if let process {
                    InfoView(process: process, ports: connection.ports[process.name] ?? [])
                } else {
                    EmptyStateView(systemImage: "info.circle", title: "No process selected")
                }
            }
        }
    }

    private var logTargets: [String] {
        if allProcesses { return connection.processes.map(\.name) }
        return processName.map { [$0] } ?? []
    }
}

private struct LogsView: View {
    let connection: ServerConnection
    let processes: [String]
    @State private var streamer = LogStreamer()
    @State private var follow = true
    @State private var wrap = true
    @State private var search = ""

    private var visibleLines: [LogLine] {
        guard !search.isEmpty else { return streamer.lines }
        return streamer.lines.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search logs", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Toggle("Wrap", isOn: $wrap).toggleStyle(.checkbox)
                Spacer()
                if let error = streamer.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Text("\(streamer.lines.count) lines").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Copy") { copyAll() }.disabled(streamer.lines.isEmpty)
                Button("Clear") { streamer.clear() }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLines) { line in
                            LogLineView(line: line, showProcess: processes.count > 1, wrap: wrap)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: streamer.lines.last?.id) { _, last in
                    if follow, search.isEmpty, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .overlay {
                if processes.isEmpty {
                    Text("Select a process").foregroundStyle(.secondary)
                } else if streamer.lines.isEmpty {
                    Text(streamer.isStreaming ? "Waiting for output…" : "No output").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: processes) {
            streamer.start(client: connection.client, processes: processes, tail: 1000)
        }
        .onDisappear { streamer.stop() }
    }

    private func copyAll() {
        let text = visibleLines.map { processes.count > 1 ? "[\($0.process)] \($0.text)" : $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogLineView: View {
    let line: LogLine
    let showProcess: Bool
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showProcess {
                Text(line.process)
                    .foregroundStyle(Self.color(for: line.process))
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)
            }
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
        }
        .font(.system(.callout, design: .monospaced))
    }

    private static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown]

    /// Stable per-process color (Swift's `hashValue` is randomized per launch, so not that).
    static func color(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

private struct ConfigView: View {
    let connection: ServerConnection
    let processName: String
    @State private var config: ProcessConfig?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let config {
                    if let command = config.command {
                        LabeledContent("Command") { Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                    }
                    if let dir = config.workingDir, !dir.isEmpty {
                        LabeledContent("Working directory") { Text(dir).textSelection(.enabled) }
                    }
                    if let replicas = config.replicas, replicas > 1 {
                        LabeledContent("Replicas") { Text("\(replicas)") }
                    }
                    Divider()
                    Text(config.prettyJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            do {
                config = try await connection.client.config(processName)
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}

private struct InfoView: View {
    let process: ProcessState
    let ports: [Int]

    var body: some View {
        ScrollView {
            Form {
                LabeledContent("Status", value: process.status)
                LabeledContent("PID", value: process.isRunning ? "\(process.pid)" : "—")
                LabeledContent("Restarts", value: "\(process.restarts)")
                LabeledContent("Last exit code", value: "\(process.exitCode)")
                LabeledContent("Readiness probe", value: process.hasReadyProbe ? process.isReady : "none")
                LabeledContent("Started", value: Formatting.time(process.processStartTime))
                LabeledContent("Ready since", value: Formatting.time(process.processReadyTime))
                LabeledContent("Ended", value: Formatting.time(process.processEndTime))
                LabeledContent("Last output", value: Formatting.time(process.lastActivityTime))
                LabeledContent("Listening ports") {
                    if ports.isEmpty { Text("none") } else { PortChips(ports: ports) }
                }
            }
            .formStyle(.grouped)
        }
    }
}
