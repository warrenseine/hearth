import Foundation
import HearthKit

/// The app's single composition root: one instance of each shared service, created once at
/// launch and handed down through the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    let store: HearthStore
    var settings = AppSettings.load() {
        didSet {
            settings.save()
            if settings.processComposePath != oldValue.processComposePath {
                store.setBinaryOverride(settings.processComposePath.isEmpty ? nil : settings.processComposePath)
            }
        }
    }
    var availableUpdate: ReleaseInfo?
    private var started = false

    init() {
        let settings = AppSettings.load()
        store = HearthStore(
            registry: Self.makeProjectRegistry(),
            binaryOverride: settings.processComposePath.isEmpty ? nil : settings.processComposePath
        )
    }

    /// Idempotent: both the main window and the menu bar extra call it, whichever appears first.
    func start() {
        guard !started else { return }
        started = true
        store.start()
        Task { await checkForUpdate() }
    }

    func checkForUpdate() async {
        guard let latest = try? await ReleaseChecker.latestRelease() else { return }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        if ReleaseChecker.isNewer(latest: latest.tagName, than: currentVersion) {
            availableUpdate = latest
        }
    }

    func openInTerminal(_ connection: ServerConnection) {
        guard let binary = store.binaryPath else { return }
        try? TerminalLauncher.attach(
            endpoint: connection.endpoint,
            token: connection.token,
            binary: binary,
            directory: connection.invocation?.workingDirectory,
            app: settings.terminalApp
        )
    }

    private static func makeProjectRegistry() -> ProjectRegistry {
        if let registry = try? ProjectRegistry() { return registry }
        // The store file exists but failed to decode (e.g. hand-edited into invalid JSON).
        // Starting fresh beats refusing to launch.
        let fallbackURL = ProjectRegistry.defaultStoreURL()
        try? FileManager.default.removeItem(at: fallbackURL)
        if let registry = try? ProjectRegistry() { return registry }
        return (try? ProjectRegistry(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")))!
    }
}

/// Lightweight user-facing settings, persisted as JSON in UserDefaults.
struct AppSettings: Codable, Equatable {
    var terminalApp: TerminalApp = .terminal
    var launchAtLogin: Bool = false
    /// Empty means auto-detect.
    var processComposePath: String = ""

    private static let defaultsKey = "ai.hearth.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
