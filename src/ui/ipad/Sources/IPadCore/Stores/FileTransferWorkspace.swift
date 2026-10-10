import Foundation

@MainActor public protocol FileTransferWorkspaceProtocol: AnyObject {
    func prepareFile(name: String) throws -> URL
    func prepareDirectory(name: String) throws -> URL
    func importFile(from source: URL) throws -> URL
    func cleanup() throws
}
@MainActor public final class FileTransferWorkspace: FileTransferWorkspaceProtocol {
    private let base: URL
    private var root: URL?
    public init(base: URL = FileManager.default.temporaryDirectory) { self.base = base }
    private func prepareRoot() throws -> URL {
        try cleanup()
        let url = base.appendingPathComponent("ipad-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url
        return url
    }
    public func prepareFile(name: String) throws -> URL {
        try prepareRoot().appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }
    public func prepareDirectory(name: String) throws -> URL {
        let url = try prepareFile(name: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public func importFile(from source: URL) throws -> URL {
        let target = try prepareFile(name: source.lastPathComponent)
        // 复制在安全作用域有效期间同步完成；异步服务以后只读这个沙盒副本。
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }
    public func cleanup() throws {
        guard let root else { return }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        self.root = nil
    }
}
