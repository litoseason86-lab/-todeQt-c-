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
    func selectTheme(_ value: String) throws {
        if let appearanceError { throw appearanceError }
        snapshot.appearance = "theme"; snapshot.backgroundTheme = value; onChanged?()
    }
    func setUseWallpaper(_ value: Bool) throws {
        if let appearanceError { throw appearanceError }
        snapshot.useWallpaper = value; onChanged?()
    }
    func pause() throws { calls.append("pause"); if !pauseResult { throw CocoaError(.fileWriteUnknown) } }
    func resume() throws { calls.append("resume"); if !resumeResult { throw CocoaError(.fileWriteUnknown) } }
    func capture(title: String, categoryID: Int, sourceTaskID: Int) throws -> Int {
        calls.append("capture:\(title):\(categoryID):\(sourceTaskID)")
        if captureResult <= 0 { throw CocoaError(.fileWriteUnknown) }
        return captureResult
    }
    func select(page: String) throws { calls.append("select:\(page)") }
}
