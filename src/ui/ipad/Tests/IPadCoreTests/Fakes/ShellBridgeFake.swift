import Foundation
import IPadCore

@MainActor final class ShellBridgeFake: ShellBridgeProtocol {
    var onChanged: (() -> Void)?
    var onTimerChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var snapshot = ShellSnapshot()
    var timerSnapshot = ShellTimerSnapshot()
    var fullReads = 0
    var timerReads = 0
    var timerError: Error?
    var error: Error?
    var appearanceError: Error?
    var calls: [String] = []
    var captureResult = 1
    var pauseResult = true
    var resumeResult = true
    func readTimer() throws -> ShellTimerSnapshot { timerReads += 1; if let timerError { throw timerError }; return timerSnapshot }
    func read() throws -> ShellSnapshot { fullReads += 1; calls.append("read"); if let error { throw error }; return snapshot }
    func setAppearance(_ value: String) throws { if let appearanceError { throw appearanceError }; snapshot.appearance = value; onChanged?() }
    func pause() -> Bool { calls.append("pause"); return pauseResult }
    func resume() -> Bool { calls.append("resume"); return resumeResult }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) -> Int { calls.append("capture:\(title):\(categoryID):\(sourceTaskID)"); return captureResult }
    func select(page: String) { calls.append("select:\(page)") }
}
