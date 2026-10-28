import SwiftUI
import HearthKit

struct MenuBarContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let entries = environment.store.entries
        let running = entries.filter { $0.connection != nil }
        let stopped = entries.filter { $0.connection == nil }
        VStack(alignment: .leading, spacing: 0) {
            Text("Hearth").font(.headline)
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
                        section("Running", running)
                        section("Stopped", stopped)
                    }
                    .padding(.vertical, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // The popover sizes to fit, and a ScrollView has no ideal height of its own, so
                // with only a max it collapsed to zero and the list was invisible. Pin it to the
                // measured content height, capped so a long list scrolls.
                .frame(height: min(listHeight, 420))
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
        // The popover's content is rebuilt each time it opens, so this runs on every open.
        .onAppear { Task { await environment.store.refreshPullRequests() } }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [ProjectEntry]) -> some View {
        if !entries.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ForEach(entries) { entry in
                MenuBarProjectRow(entry: entry)
            }
        }
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
                if let pullRequest = store.pullRequest(for: entry) {
                    PullRequestLink(pullRequest: pullRequest)
                }
                Spacer()
                if store.isPending(entry) {
                    ProgressView().controlSize(.small)
                } else if entry.connection != nil {
                    iconButton("stop.fill") { await store.down(entry) }
                        .help("Down: stop all processes and the server")
                } else if let project = entry.project {
                    iconButton("play.fill") { await store.up(project) }
                        .help("Up: start headless in the background")
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

private struct PullRequestLink: View {
    let pullRequest: PullRequest
    @State private var isHovered = false
    @State private var showsTitle = false

    var body: some View {
        Link("#\(pullRequest.number)", destination: pullRequest.url)
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
            // Not `.help`: tooltips never show in a MenuBarExtra window (it doesn't become key).
            .onHover { hovering in
                isHovered = hovering
                guard hovering else { showsTitle = false; return }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if isHovered { showsTitle = true }
                }
            }
            .popover(isPresented: $showsTitle, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pullRequest.title).font(.callout)
                    Text("\(label) #\(pullRequest.number)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
    }

    private var label: String {
        if pullRequest.isDraft && pullRequest.state == .open { return "Draft PR" }
        return switch pullRequest.state {
        case .open: "Open PR"
        case .merged: "Merged PR"
        case .closed: "Closed PR"
        }
    }

    private var color: Color {
        if pullRequest.isDraft && pullRequest.state == .open { return .secondary }
        return switch pullRequest.state {
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }
}
