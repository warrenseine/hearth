import SwiftUI
import HearthKit

enum SidebarSelection: Hashable {
    case entry(String)
    case settings
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: SidebarSelection?
    @State private var isAddProjectPresented = false

    private var store: HearthStore { environment.store }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Not List(selection:) -- on this toolchain (as found in opossum-desktop), List's
                // underlying NSTableView swallows row clicks without updating the selection
                // binding. A plain ScrollView of rows that set `selection` themselves works.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader("Projects")
                        ForEach(store.entries) { entry in
                            SidebarEntryRow(entry: entry, isSelected: selection == .entry(entry.id))
                                .contentShape(Rectangle())
                                .onTapGesture { selection = .entry(entry.id) }
                        }
                        if store.entries.isEmpty {
                            Text("Nothing yet")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(8)
                }
                Divider()
                VStack(spacing: 2) {
                    SidebarRow(title: "Add Project…", systemImage: "plus", isSelected: false)
                        .contentShape(Rectangle())
                        .onTapGesture { isAddProjectPresented = true }
                    SidebarRow(title: "Settings", systemImage: "gearshape", isSelected: selection == .settings)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = .settings }
                }
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            // Suppress the system focus ring on whichever row rendered first: rows draw their
            // own selection highlight, and the ring reads as a second, stuck selection.
            .focusEffectDisabled()
        } detail: {
            detail
        }
        .sheet(isPresented: $isAddProjectPresented) {
            AddProjectSheet { added in
                selection = .entry("project:\(added.id)")
            }
            .environment(environment)
        }
        .onChange(of: store.entries.map(\.id)) { _, ids in
            // Keep a sensible selection as servers come and go.
            if case .entry(let id) = selection, !ids.contains(id) { selection = ids.first.map(SidebarSelection.entry) }
            if selection == nil, let first = ids.first { selection = .entry(first) }
        }
        .onAppear {
            if selection == nil, let first = store.entries.first { selection = .entry(first.id) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .settings:
            SettingsView()
        case .entry(let id):
            if let entry = store.entry(id: id) {
                ProjectDetailView(entry: entry)
                    .id(id)
            } else {
                emptyState
            }
        case nil:
            emptyState
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "flame",
            title: store.binaryPath == nil ? "process-compose not found" : "No projects yet",
            message: store.binaryPath == nil
                ? "Install process-compose (e.g. `brew install f1bonacc1/tap/process-compose`), or set its path in Settings. Running servers are still discovered."
                : "Add a folder with a process-compose.yaml, or start one from a terminal: running servers show up here automatically.",
            actionTitle: "Add Project…"
        ) { isAddProjectPresented = true }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SidebarEntryRow: View {
    let entry: ProjectEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(kind: dotKind)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var dotKind: StatusDot.Kind {
        guard let connection = entry.connection else { return .stopped }
        switch connection.status {
        case .connected: return StatusDot.Kind(connection.overallPhase)
        case .connecting: return .transitioning
        case .needsToken, .unreachable: return .failed
        }
    }

    private var subtitle: String {
        if entry.project?.isOrphaned == true { return "folder not found" }
        guard let connection = entry.connection else { return "stopped" }
        switch connection.status {
        case .connecting: return "connecting…"
        case .needsToken: return "needs API token"
        case .unreachable: return "unreachable"
        case .connected:
            let counts = "\(connection.runningCount)/\(connection.processes.count) running"
            return entry.project == nil ? "\(counts) · attached" : counts
        }
    }
}
