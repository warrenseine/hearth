import SwiftUI
import HearthKit

struct StatusDot: View {
    enum Kind { case running, transitioning, stopped, failed }
    let kind: Kind

    private var color: Color {
        switch kind {
        case .running: .green
        case .transitioning: .yellow
        case .stopped: .secondary
        case .failed: .red
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

extension StatusDot.Kind {
    init(_ phase: ProcessState.Phase) {
        switch phase {
        case .running: self = .running
        case .transitioning: self = .transitioning
        case .stopped: self = .stopped
        case .failed: self = .failed
        }
    }
}
