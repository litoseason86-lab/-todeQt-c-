import Foundation
import Observation

public struct TimelineDateSelection: Equatable, Sendable {
    public var date: String
    public var isFuture: Bool
    public init(date: String, isFuture: Bool) { self.date = date; self.isFuture = isFuture }
}

public struct SessionEditorDraft: Equatable, Sendable {
    public var id: Int
    public var taskID: Int
    public var startTime: String
    public var durationMinutes: Int
    public var durationEdited: Bool
    public var startEdited: Bool
    public var isRest: Bool
    public init(original: SessionValue) {
        id = original.id; taskID = original.taskID; startTime = original.startTime
        durationMinutes = max(0, Int((Double(original.durationSeconds) / 60.0).rounded()))
        durationEdited = false; startEdited = false; isRest = original.isRest
    }
}

@MainActor @Observable public final class TimelineStore {
    public private(set) var sessions: [SessionValue] = []
    public private(set) var selectedDate: String
    public private(set) var isFutureDate: Bool
    public private(set) var totalSeconds = 0
    public private(set) var statistics = DayStatistics()
    public private(set) var taskOptions: [SessionTaskOption] = []
    public private(set) var error = ""
    @ObservationIgnored private let history: any FocusHistoryBridgeProtocol
    @ObservationIgnored private let statisticsBridge: any StatisticsBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    public var canAddManualSession: Bool { !isFutureDate }
    public var visibleSessions: [SessionValue] {
        sessions.filter { !pendingDeletion.state.active || $0.id != pendingDeletion.pendingSessionID || $0.isRest != pendingDeletion.state.sessionIsRest }
    }

    public init(history: any FocusHistoryBridgeProtocol, statistics: any StatisticsBridgeProtocol,
                pendingDeletion: PendingDeletionStore, selection: TimelineDateSelection) {
        self.history = history; statisticsBridge = statistics; self.pendingDeletion = pendingDeletion
        selectedDate = selection.date; isFutureDate = selection.isFuture
        history.onChanged = { [weak self] in self?.refresh() }
        statistics.onFailure = { [weak self] in self?.error = $0 }
        refresh()
    }
    public func selectDate(_ selection: TimelineDateSelection) {
        selectedDate = selection.date; isFutureDate = selection.isFuture; refresh()
    }
    public func refresh() {
        do {
            let timeline = try history.dayTimeline(date: selectedDate)
            let total = try history.dayTotalDuration(date: selectedDate)
            let day = try statisticsBridge.dayStats(date: selectedDate)
            let options = try history.taskOptions(date: selectedDate)
            sessions = timeline; totalSeconds = total; statistics = day; taskOptions = options; error = ""
        } catch { self.error = error.localizedDescription }
    }
    public func formatDuration(_ seconds: Int) -> String { history.formatDuration(seconds: seconds) }
    @discardableResult public func addManualSession(taskID: Int, startTime: String, durationMinutes: Int) -> Bool {
        guard canAddManualSession, pendingDeletion.commitIfNeeded() else { return false }
        do { _ = try history.addManualSession(taskID: taskID, startTime: startTime, durationMinutes: durationMinutes); refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult public func updateSession(_ draft: SessionEditorDraft, original: SessionValue) -> Bool {
        guard pendingDeletion.commitIfNeeded() else { return false }
        var changes = SessionChanges()
        if draft.startEdited && draft.startTime != original.startTime { changes.startTime = draft.startTime }
        if draft.durationEdited && draft.durationMinutes != Int((Double(original.durationSeconds) / 60.0).rounded()) { changes.durationSeconds = draft.durationMinutes * 60 }
        if draft.taskID != original.taskID && !original.isRest && !draft.isRest { changes.task = draft.taskID > 0 ? .selected(draft.taskID) : SessionTaskChange.none }
        if draft.isRest != original.isRest { changes.isRest = draft.isRest }
        do {
            if original.isRest { try history.updateRestSession(id: original.id, changes: changes) }
            else { try history.updateSession(id: original.id, changes: changes) }
            refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    public func taskOptions(original: SessionValue) throws -> [SessionTaskOption] {
        var options = try history.taskOptions(date: selectedDate)
        if original.taskID > 0 && !options.contains(where: { $0.taskID == original.taskID }) {
            var old = SessionTaskOption(); old.taskID = original.taskID; old.title = original.taskTitle; options.insert(old, at: 0)
        }
        return options
    }
    @discardableResult public func deleteSession(_ session: SessionValue) -> Bool {
        guard pendingDeletion.requestSession(id: session.id, title: session.taskTitle, isRest: session.isRest) else { return false }
        return true
    }
}
