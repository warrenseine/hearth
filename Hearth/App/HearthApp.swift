import SwiftUI
import HearthKit

@main
struct HearthApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // `Window`, not `WindowGroup`: a group spawns a fresh window on every
        // `openWindow(id:)`, so "Open Hearth" from the menu bar stacked up duplicates. A single
        // `Window` scene is brought to front (or reopened if closed) instead.
        Window("Hearth", id: "main") {
            RootView()
                .environment(environment)
                .frame(minWidth: 1000, minHeight: 620)
                .task { environment.start() }
                .onChange(of: scenePhase) { _, phase in
                    environment.store.setVisible(phase == .active)
                }
        }
        // Not .contentSize: a ScrollView full of rows reports its full content height as
        // "ideal", so the window would keep growing to fit every row instead of scrolling.
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContentView()
                .environment(environment)
                .task { environment.start() }
        } label: {
            MenuBarLabel()
                .environment(environment)
        }
        .menuBarExtraStyle(.window)
    }
}
