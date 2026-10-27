import SwiftUI
import HearthKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isCheckingUpdate = false

    var body: some View {
        @Bindable var environment = environment
        Form {
            Section("process-compose") {
                TextField("Binary path", text: $environment.settings.processComposePath, prompt: Text("auto-detect"))
                if let path = environment.store.binaryPath {
                    Text("Using \(path)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not found. Install it (brew install f1bonacc1/tap/process-compose) or enter its path.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Terminal") {
                Picker("Open the TUI in", selection: $environment.settings.terminalApp) {
                    ForEach(TerminalApp.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Startup") {
                Toggle("Launch Hearth at login", isOn: $environment.settings.launchAtLogin)
                    .onChange(of: environment.settings.launchAtLogin) { _, newValue in
                        LoginItemManager.setEnabled(newValue)
                    }
            }

            Section("Registered projects") {
                if environment.store.projects.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    ForEach(environment.store.projects) { project in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.lastKnownPath ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            if project.isOrphaned {
                                Text("folder not found").font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Remove") { Task { await environment.store.removeProject(id: project.id) } }
                                .font(.caption)
                        }
                    }
                }
            }

            Section("Updates") {
                if let update = environment.availableUpdate {
                    Link("Version \(update.tagName) is available — open release notes", destination: update.htmlURL)
                } else {
                    Text("Hearth is unsigned; updates ship via Homebrew (`brew upgrade --cask hearth`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(isCheckingUpdate ? "Checking…" : "Check for updates") {
                    Task {
                        isCheckingUpdate = true
                        await environment.checkForUpdate()
                        isCheckingUpdate = false
                    }
                }
                .disabled(isCheckingUpdate)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
