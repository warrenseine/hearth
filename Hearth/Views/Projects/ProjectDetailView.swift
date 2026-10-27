import SwiftUI
import HearthKit

struct ProjectDetailView: View {
    let entry: ProjectEntry
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedProcess: String?
    @State private var filter = ""
    @State private var isRemoveConfirmPresented = false

    private var store: HearthStore { environment.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = store.lastError {
                Banner(text: message, kind: .error) { store.lastError = nil }
            }
            if let connection = entry.connection {
                content(for: connection)
            } else {
                stoppedState
            }
        }
        .navigationTitle(entry.title)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter processes")
        .toolbar { toolbar }
        .confirmationDialog("Remove \(entry.title) from Hearth?", isPresented: $isRemoveConfirmPresented) {
            Button("Remove", role: .destructive) {
                if let project = entry.project { Task { await store.removeProject(id: project.id) } }
            }
        } message: {
            Text("The folder and any running processes are left alone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.title).font(.title2.weight(.semibold))
                    if entry.connection != nil {
                        Badge(text: entry.isOwned ? "launched by Hearth" : "attached", color: entry.isOwned ? .orange : .blue)
                    }
                }
                Group {
                    if let folder = folderPath {
                        Text(folder).textSelection(.enabled)
                    }
                    if let connection = entry.connection {
                        Text(serverSummary(connection)).textSelection(.enabled)
                    } else if let project = entry.project {
                        Text(([project.configFiles.joined(separator: ", ")] + (project.namespaces.isEmpty ? [] : ["namespaces: " + project.namespaces.joined(separator: ", ")])).joined(separator: " · "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var folderPath: String? {
        entry.project?.lastKnownPath ?? entry.connection?.invocation?.workingDirectory
    }

    private func serverSummary(_ connection: ServerConnection) -> String {
        var parts: [String] = []
        if let project = connection.project {
            parts.append("up \(Formatting.duration(nanoseconds: project.upTime))")
            parts.append(project.version)
            if !project.fileNames.isEmpty { parts.append(project.fileNames.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) }
        }
        parts.append("\(connection.endpoint.kindLabel): \(connection.endpoint.description)")
        if let pid = connection.invocation?.pid { parts.append("pid \(pid)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if store.isPending(entry) {
                ProgressView().controlSize(.small)
            } else if let connection = entry.connection {
                Button {
                    Task { await connection.reloadConfiguration() }
                } label: {
                    Label("Reload Config", systemImage: "arrow.clockwise.circle")
                }
                .help("Re-read the config files and apply changes")
                Button {
                    Task { await store.down(entry) }
                } label: {
                    Label("Down", systemImage: "stop.fill")
                }
                .help("Stop all processes and the process-compose server")
            } else if let project = entry.project {
                Button {
                    Task { await store.up(project) }
                } label: {
                    Label("Up", systemImage: "play.fill")
                }
                .help("Start this project headless (process-compose up --detached)")
                .disabled(project.isOrphaned || store.binaryPath == nil)
            }
        }
        ToolbarItem {
            Menu {
                if let folder = folderPath {
                    Button("Show Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                    }
                }
                if let connection = entry.connection {
                    Button("Open TUI in \(environment.settings.terminalApp.rawValue)") { environment.openInTerminal(connection) }
                        .disabled(store.binaryPath == nil)
                    if case .unix(let path) = connection.endpoint {
                        Button("Copy Socket Path") { copy(path) }
                    }
                }
                if entry.isOwned, let project = entry.project {
                    Button("Show process-compose Log") {
                        NSWorkspace.shared.open(Launcher.logFile(projectID: project.id))
                    }
                }
                if entry.project != nil {
                    Divider()
                    Button("Remove from Hearth…", role: .destructive) { isRemoveConfirmPresented = true }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for connection: ServerConnection) -> some View {
        switch connection.status {
        case .needsToken:
            TokenPromptView(connection: connection)
        case .unreachable(let message) where connection.processes.isEmpty:
            EmptyStateView(systemImage: "bolt.horizontal.circle", title: "Can't reach the server", message: message)
        case .connecting where connection.processes.isEmpty:
            ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if let error = connection.lastActionError {
                Banner(text: error, kind: .error) { connection.clearActionError() }
            }
            VSplitView {
                ProcessTableView(connection: connection, filter: filter, selection: $selectedProcess)
                    .frame(minHeight: 140, idealHeight: 260)
                ProcessDetailView(connection: connection, processName: selectedProcess)
                    .frame(minHeight: 200, idealHeight: 360)
            }
        }
    }

    private var stoppedState: some View {
        Group {
            if let project = entry.project, project.isOrphaned {
                EmptyStateView(systemImage: "questionmark.folder", title: "Folder not found", message: "It was moved to another volume or deleted. Remove the project and add it again.")
            } else {
                EmptyStateView(
                    systemImage: "flame",
                    title: "Not running",
                    message: "Up starts it headless in the background; it keeps running after Hearth quits.",
                    actionTitle: store.binaryPath == nil ? nil : "Up"
                ) {
                    if let project = entry.project { Task { await store.up(project) } }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct Banner: View {
    enum Kind { case error, info }
    let text: String
    let kind: Kind
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .error ? .red : .blue)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background((kind == .error ? Color.red : Color.blue).opacity(0.08))
    }
}

private struct TokenPromptView: View {
    let connection: ServerConnection
    @Environment(AppEnvironment.self) private var environment
    @State private var token = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("This server requires an API token").font(.title3.weight(.semibold))
            Text("It was started with PC_API_TOKEN or --token-file. Paste the token to connect; Hearth keeps it in your Keychain.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("Token", text: $token)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(save)
            Button("Connect", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(token.isEmpty)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        guard !token.isEmpty else { return }
        environment.store.setToken(token, for: connection)
    }
}
