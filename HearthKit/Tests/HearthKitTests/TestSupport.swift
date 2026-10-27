import Foundation

enum TestFixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func lines(_ name: String) throws -> [String] {
        try String(contentsOf: url(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-tests-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
