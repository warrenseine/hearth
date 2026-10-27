import SwiftUI
import HearthKit

/// The process list. Hand-rolled rows rather than `Table`: like `List`, `Table` sits on an
/// NSTableView, whose click/selection handling was unreliable on this toolchain (see RootView).
struct ProcessTableView: View {
    let connection: ServerConnection
    let filter: String
    @Binding var selection: String?
    @State private var sort: SortKey = .name
    @State private var ascending = true

    enum SortKey: String, CaseIterable {
        case name, namespace, status, restarts, age, cpu, mem
    }

    enum Column {
        static let nameMin: CGFloat = 140
        static let namespace: CGFloat = 90
        static let status: CGFloat = 96
        static let health: CGFloat = 80
        static let pid: CGFloat = 60
        static let restarts: CGFloat = 54
        static let exit: CGFloat = 40
        static let age: CGFloat = 64
        static let cpu: CGFloat = 54
        static let mem: CGFloat = 70
        static let ports: CGFloat = 130
        static let actions: CGFloat = 56
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 12

        /// Narrowest width at which every column fits; below it the table scrolls sideways
        /// instead of overflowing (which centered the row and squeezed the sidebar).
        static let minimumTableWidth: CGFloat = {
            let fixed: [CGFloat] = [8, nameMin, namespace, status, health, pid, restarts, exit, age, cpu, mem, ports, actions]
            return fixed.reduce(0, +) + spacing * CGFloat(fixed.count - 1) + padding * 2
        }()
    }

    private var rows: [ProcessState] {
        let filtered = filter.isEmpty ? connection.processes : connection.processes.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.namespace.localizedCaseInsensitiveContains(filter)
                || $0.status.localizedCaseInsensitiveContains(filter)
        }
        let sorted = filtered.sorted { a, b in
            switch sort {
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .namespace: (a.namespace, a.name) < (b.namespace, b.name)
            case .status: (a.status, a.name) < (b.status, b.name)
            case .restarts: (a.restarts, a.name) < (b.restarts, b.name)
            case .age: (a.age, a.name) < (b.age, b.name)
            case .cpu: (a.cpu, a.name) < (b.cpu, b.name)
            case .mem: (a.mem, a.name) < (b.mem, b.name)
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                table.frame(width: max(geometry.size.width, Column.minimumTableWidth), height: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .onAppear {
            if selection == nil { selection = connection.processes.first?.name }
        }
        .onChange(of: connection.processes.map(\.name)) { _, names in
            if selection == nil || !names.contains(selection!) { selection = names.first }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { process in
                        ProcessRow(
                            process: process,
                            ports: connection.ports[process.name] ?? [],
                            isBusy: connection.busy.contains(process.name),
                            isSelected: selection == process.name,
                            connection: connection
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selection = process.name }
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: Column.spacing) {
            Color.clear.frame(width: 8, height: 1)
            header("Name", .name, width: nil)
            header("Namespace", .namespace, width: Column.namespace)
            header("Status", .status, width: Column.status)
            plainHeader("Health", width: Column.health)
            plainHeader("PID", width: Column.pid, alignment: .trailing)
            header("Restarts", .restarts, width: Column.restarts, alignment: .trailing)
            plainHeader("Exit", width: Column.exit, alignment: .trailing)
            header("Age", .age, width: Column.age, alignment: .trailing)
            header("CPU", .cpu, width: Column.cpu, alignment: .trailing)
            header("Memory", .mem, width: Column.mem, alignment: .trailing)
            plainHeader("Ports", width: Column.ports)
            Color.clear.frame(width: Column.actions, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func header(_ title: String, _ key: SortKey, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Button {
            if sort == key { ascending.toggle() } else { sort = key; ascending = true }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sort == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
            .frame(width: width, alignment: alignment)
            .frame(minWidth: width == nil ? Column.nameMin : nil, maxWidth: width == nil ? .infinity : nil, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    private func plainHeader(_ title: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Text(title).frame(width: width, alignment: alignment).frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

private struct ProcessRow: View {
    let process: ProcessState
    let ports: [Int]
    let isBusy: Bool
    let isSelected: Bool
    let connection: ServerConnection
    @State private var isHovered = false

    private typealias Column = ProcessTableView.Column

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(kind: StatusDot.Kind(process.phase))
            Text(process.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: Column.nameMin, maxWidth: .infinity, alignment: .leading)
            Text(process.namespace).foregroundStyle(.secondary).lineLimit(1).frame(width: Column.namespace, alignment: .leading)
            Text(process.status).lineLimit(1).frame(width: Column.status, alignment: .leading)
            healthView.frame(width: Column.health, alignment: .leading)
            Text(process.isRunning ? "\(process.pid)" : "—").monospacedDigit().frame(width: Column.pid, alignment: .trailing)
            Text("\(process.restarts)").monospacedDigit()
                .foregroundStyle(process.restarts > 0 ? .orange : .primary)
                .frame(width: Column.restarts, alignment: .trailing)
            Text(exitText).monospacedDigit()
                .foregroundStyle(exitText != "—" && process.exitCode != 0 ? .red : .secondary)
                .frame(width: Column.exit, alignment: .trailing)
            Text(Formatting.duration(nanoseconds: process.age)).monospacedDigit().frame(width: Column.age, alignment: .trailing)
            Text(Formatting.cpu(process.cpu, running: process.isRunning)).monospacedDigit().frame(width: Column.cpu, alignment: .trailing)
            Text(process.isRunning ? Formatting.bytes(process.mem) : "—").monospacedDigit().frame(width: Column.mem, alignment: .trailing)
            PortChips(ports: ports).frame(width: Column.ports, alignment: .leading)
            actions
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        .onHover { isHovered = $0 }
        .contextMenu {
            if process.canStart { Button("Start") { Task { await connection.start(process.name) } } }
            if process.isRunning {
                Button("Stop") { Task { await connection.stop(process.name) } }
                Button("Restart") { Task { await connection.restart(process.name) } }
            }
            Divider()
            if process.isRunning { Button("Copy PID") { copy("\(process.pid)") } }
            Button("Copy Name") { copy(process.name) }
            ForEach(ports, id: \.self) { port in
                Button("Open localhost:\(port)") { PortChips.open(port) }
            }
        }
    }

    private var exitText: String {
        process.isRunning || process.status == "Pending" || process.status == "Disabled" ? "—" : "\(process.exitCode)"
    }

    @ViewBuilder
    private var healthView: some View {
        switch process.health {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notReady: Label("Not ready", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .noProbe: Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                if process.canStart {
                    iconButton("play.fill", help: "Start") { await connection.start(process.name) }
                }
                if process.isRunning {
                    iconButton("arrow.clockwise", help: "Restart") { await connection.restart(process.name) }
                    iconButton("stop.fill", help: "Stop") { await connection.stop(process.name) }
                }
            }
        }
        .frame(width: Column.actions, alignment: .trailing)
        .opacity(isHovered || isSelected || isBusy ? 1 : 0.35)
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct PortChips: View {
    let ports: [Int]

    static func open(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(3), id: \.self) { port in
                Button(":\(port)") { Self.open(port) }
                    .buttonStyle(.borderless)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                    .help("Open http://localhost:\(port)")
            }
            if ports.count > 3 {
                Text("+\(ports.count - 3)").font(.caption).foregroundStyle(.secondary)
                    .help(ports.dropFirst(3).map { ":\($0)" }.joined(separator: " "))
            }
        }
    }
}
