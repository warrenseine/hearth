import Testing
import Foundation
@testable import HearthKit

@Suite("ProjectRegistry")
struct ProjectRegistryTests {
    private func makeProjectDir(_ files: [String: String]) throws -> URL {
        let dir = try makeTempDir("project")
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("discovers process-compose.yaml and its override")
    func discoversWithOverride() throws {
        let dir = try makeProjectDir(["process-compose.yaml": "processes: {}", "process-compose.override.yaml": "processes: {}"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ProjectRegistry.discoverConfigFiles(in: dir) == ["process-compose.yaml", "process-compose.override.yaml"])
    }

    @Test("ignores a Docker compose.yaml but takes one that declares processes")
    func composeYamlDisambiguation() throws {
        let docker = try makeProjectDir(["compose.yaml": "services:\n  web: {}"])
        defer { try? FileManager.default.removeItem(at: docker) }
        #expect(ProjectRegistry.discoverConfigFiles(in: docker).isEmpty)
        let pc = try makeProjectDir(["compose.yaml": "version: \"0.5\"\nprocesses:\n  web: {}"])
        defer { try? FileManager.default.removeItem(at: pc) }
        #expect(ProjectRegistry.discoverConfigFiles(in: pc) == ["compose.yaml"])
    }

    @Test("registers, resolves, re-registers in place, persists, unregisters")
    func lifecycle() async throws {
        let dir = try makeProjectDir(["process-compose.yml": "processes: {}"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }

        let registry = try ProjectRegistry(storeURL: store)
        let entry = try await registry.register(directory: dir)
        #expect(entry.configFiles == ["process-compose.yml"])
        #expect(entry.configFilePaths == [dir.standardizedFileURL.appendingPathComponent("process-compose.yml").path])

        let again = try await registry.register(directory: dir, namespaces: ["jobs"])
        #expect(again.id == entry.id)
        #expect(await registry.all().count == 1)

        let context = try #require(await registry.resolve(id: entry.id))
        #expect(context.namespaces == ["jobs"])

        let reloaded = try ProjectRegistry(storeURL: store)
        #expect(await reloaded.entry(id: entry.id)?.name == dir.lastPathComponent)

        try FileManager.default.removeItem(at: dir)
        #expect(await reloaded.resolve(id: entry.id) == nil)
        #expect(await reloaded.entry(id: entry.id)?.isOrphaned == true)

        try await reloaded.unregister(id: entry.id)
        #expect(await reloaded.all().isEmpty)
    }

    @Test("refuses a folder with no config file")
    func noConfig() async throws {
        let dir = try makeProjectDir([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = try ProjectRegistry(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString).json"))
        await #expect(throws: ProjectRegistryError.self) { try await registry.register(directory: dir) }
    }
}
