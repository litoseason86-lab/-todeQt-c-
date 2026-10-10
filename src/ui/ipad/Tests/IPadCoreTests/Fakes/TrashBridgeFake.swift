import IPadCore

@MainActor final class TrashBridgeFake: TrashBridgeProtocol {
    var onChanged: (() -> Void)?
    var result = TrashRead()
    var readError: Error?
    var actionResult = TrashActionResult()
    var calls: [(String, [Int])] = []
    func readItems() throws -> TrashRead { if let readError { throw readError }; return result }
    func purgeExpired() throws -> Int { calls.append(("purge", [])); return 0 }
    func restore(id: Int) throws -> TrashActionResult { calls.append(("restore", [id])); return actionResult }
    func delete(id: Int) throws -> TrashActionResult { calls.append(("delete", [id])); return actionResult }
    func empty(ids: [Int]) throws -> TrashActionResult { calls.append(("empty", ids)); return actionResult }
}
