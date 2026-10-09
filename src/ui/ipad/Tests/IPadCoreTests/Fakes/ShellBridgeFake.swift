import Foundation
import IPadCore

@MainActor final class ShellBridgeFake: ShellBridgeProtocol {
    var onChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var snapshot = ShellSnapshot()
    var error: Error?
    var calls: [String] = []
    var captureResult = 1
    var pauseResult = true
    var resumeResult = true
    func read() throws -> ShellSnapshot { calls.append("read"); if let error { throw error }; return snapshot }
    func pause() -> Bool { calls.append("pause"); return pauseResult }
    func resume() -> Bool { calls.append("resume"); return resumeResult }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int { calls.append("capture:\(title):\(categoryID):\(sourceTaskID)"); return captureResult }
    func select(page: String) { calls.append("select:\(page)") }
}
