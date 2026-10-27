import SwiftUI
import HearthKit

struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let entries = environment.store.entries
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hearth").font(.headline)
                Spacer()
                Text("\(environment.store.connections.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()
            if entries.isEmpty {
                Text("No projects or running servers.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            MenuBarProjectRow(entry: entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }
            if let error = environment.store.lastError {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).padding(8)
            }
            Divider()
            HStack {
                Button("Open Hearth") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                .keyboardShortcut("o")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .frame(width: 320)
        .padding(.vertical, 8)
    }
}

private struct MenuBarProjectRow: View {
    let entry: ProjectEntry
    @Environment(AppEnvironment.self) private var environment
    @State private var expanded = false

    private var store: HearthStore { environment.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                }
                .buttonStyle(.borderless)
                .disabled(entry.connection == nil)
                StatusDot(kind: entry.connection.map { StatusDot.Kind($0.overallPhase) } ?? .stopped)
                Text(entry.title).lineLimit(1)
                if let connection = entry.connection {
                    Text("\(connection.runningCount)/\(connection.processes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if store.isPending(entry) {
                    ProgressView().controlSize(.small)
                } else if entry.connection != nil {
                    Button("Down") { Task { await store.down(entry) } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if let project = entry.project {
                    Button("Up") { Task { await store.up(project) } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(project.isOrphaned || store.binaryPath == nil)
                }
            }
            if expanded, let connection = entry.connection {
                ForEach(connection.processes) { process in
                    HStack(spacing: 6) {
                        StatusDot(kind: StatusDot.Kind(process.phase))
                        Text(process.name).font(.callout).lineLimit(1)
                        ForEach(connection.ports[process.name]?.prefix(2).map { $0 } ?? [], id: \.self) { port in
                            Button(":\(port)") { PortChips.open(port) }
                                .buttonStyle(.borderless)
                                .font(.caption.monospacedDigit())
                        }
                        Spacer()
                        if connection.busy.contains(process.name) {
                            ProgressView().controlSize(.mini)
                        } else if process.canStart {
                            iconButton("play.fill") { await connection.start(process.name) }
                        } else if process.isRunning {
                            iconButton("arrow.clockwise") { await connection.restart(process.name) }
                            iconButton("stop.fill") { await connection.stop(process.name) }
                        }
                    }
                    .padding(.leading, 24)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func iconButton(_ systemImage: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemImage).font(.caption)
        }
        .buttonStyle(.borderless)
    }
}
