import SwiftUI
import HearthKit

struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let connections = Array(environment.store.connections.values)
        let running = connections.reduce(0) { $0 + $1.runningCount }
        let failing = connections.contains { $0.overallPhase == .failed }
        Label {
            Text(connections.isEmpty ? "" : "\(running)")
        } icon: {
            Image(systemName: failing ? "flame.fill" : "flame")
                .opacity(connections.isEmpty ? 0.5 : 1)
        }
    }
}
