import Foundation

// 后续 P2B 的口径表优先读仓库 tests/fixtures/calibers；未合入时回落到包内示例，不复制正式表。
enum FixtureReader {
    static func load(_ name: String) throws -> Data {
        if let path = ProcessInfo.processInfo.environment["PT_CALIBERS_DIR"] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name + ".json")
            if FileManager.default.fileExists(atPath: url.path) { return try Data(contentsOf: url) }
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let fixture = directory.appendingPathComponent("tests/fixtures/calibers/" + name + ".json")
            if FileManager.default.fileExists(atPath: fixture.path) { return try Data(contentsOf: fixture) }
            directory.deleteLastPathComponent()
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
