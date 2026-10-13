import IPadCore

@MainActor final class TrashBridgeFake: TrashBridgeProtocol {
    var onChanged: (() -> Void)?
    var result = TrashRead()
    var readError: Error?
    var actionResult = TrashActionResult()
    var readCount = 0
    var restoreResults: [Int: TrashActionResult] = [:]
    var actionError: Error?
    var onRestore: ((Int) -> Void)?
    var calls: [(String, [Int])] = []
    func readItems() throws -> TrashRead { readCount += 1; if let readError { throw readError }; return result }
    func purgeExpired() throws -> Int { calls.append(("purge", [])); return 0 }
    func restore(id: Int) throws -> TrashActionResult { calls.append(("restore", [id])); if let actionError { throw actionError }; onRestore?(id); return restoreResults[id] ?? actionResult }
    func delete(id: Int) throws -> TrashActionResult { calls.append(("delete", [id])); return actionResult }
    func empty(ids: [Int]) throws -> TrashActionResult { calls.append(("empty", ids)); if let actionError { throw actionError }; return actionResult }
}
