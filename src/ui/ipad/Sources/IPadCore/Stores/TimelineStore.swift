import Foundation
import Observation

// 两张时间轴表可以有同号记录；列表身份按类型和编号组合。
public extension SessionValue { var timelineID: String { "\(isRest ? "rest" : "focus")/\(id)" } }

public struct SessionEditorDraft: Equatable, Sendable {
    public var id: Int
    public var taskID: Int
    public var startTime: String
    public var durationMinutes: Int
    public var durationEdited: Bool
    public var startEdited: Bool
    public var isRest: Bool
    public init(original: SessionValue) {
        // 分钟是表单显示精度；未编辑时不会把四舍五入的值写回原记录。
        id = original.id; taskID = original.taskID; startTime = original.startTime
        durationMinutes = max(0, Int((Double(original.durationSeconds) / 60.0).rounded()))
        durationEdited = false; startEdited = false; isRest = original.isRest
    }

    // 10-13 用户要求：时长和今日目标编辑器一样分「小时」「分钟」两行，都能直接输入，行尾步进器按总分钟加减。
    // 上限沿用原单行步进器的 1440 分钟；输入框清空得到 0 分钟，改过且不足 1 分钟时不能保存。
    public static let maxDurationMinutes = 24 * 60
    public var durationHours: Int { durationMinutes / 60 }
    public var durationRemainderMinutes: Int { durationMinutes % 60 }
    public var durationValid: Bool { !durationEdited || (1...Self.maxDurationMinutes).contains(durationMinutes) }
    // 表单把草稿写回两个输入框时也会触发输入回调，所以合出的总分钟数（未夹范围）和草稿相同就不算改动：
    // 否则不足 1 分钟的旧记录（20 秒显示 0 分）会被判成「改成 0 分钟」而不能保存，
    // 超过 24 小时的旧记录会被夹成 1440 分钟提交。
    public mutating func setDurationFields(hours: String, minutes: String) {
        let typed = HourMinuteFields.minutes(hours: hours, minutes: minutes, cap: Self.maxDurationMinutes)
        guard typed != durationMinutes else { return }
        setDuration(typed)
    }
    // 步进器给出的新总分钟数；越界停在 0 或 1440，不回绕。
    public mutating func setDuration(_ minutes: Int) {
        durationMinutes = min(max(minutes, 0), Self.maxDurationMinutes); durationEdited = true
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
    public private(set) var relationAvailable = true
    public private(set) var categoryStatistics = CategoryStatistics()
    public var editorDraft: SessionEditorDraft?
    // 「补录」表单是否弹出；放在 Store 里，巡检能像其它页的新建表单一样真实弹出它截图。
    public var manualAddPresented = false
    public private(set) var editorOriginal: SessionValue?
    public private(set) var editorError = ""
    public private(set) var editorOptionsLoaded = false
    public private(set) var editorTaskOptions: [SessionTaskOption] = []
    public func openEditor(original: SessionValue?) {
        editorOriginal = original
        var value = original ?? SessionValue()
        if original == nil { value.startTime = LogicalDateNavigation.timestamp(LogicalDateNavigation.initialSessionStart(date: selectedDate)); value.durationSeconds = 1800 }
        editorDraft = SessionEditorDraft(original: value)
        editorError = ""; editorOptionsLoaded = false; reloadEditorOptions()
    }
    public func submitEditor() -> Bool {
        guard let draft = editorDraft else { return false }
        let saved: Bool
        if let original = editorOriginal { saved = updateSession(draft, original: original) }
        else { saved = addManualSession(taskID: draft.taskID, startTime: draft.startTime, durationMinutes: draft.durationMinutes) }
        if !saved { editorError = error.isEmpty ? "保存失败，请重试" : error }
        else { editorError = "" }
        return saved
    }
    public func reloadEditorOptions() {
        do { editorTaskOptions = try taskOptions(original: editorOriginal); editorOptionsLoaded = true; editorError = "" }
        catch { editorError = error.localizedDescription }
    }

    @ObservationIgnored private let history: any FocusHistoryBridgeProtocol
    @ObservationIgnored private let statisticsBridge: any StatisticsBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private let focus: (any FocusBridgeProtocol)?
    @ObservationIgnored private var selectedRelation: DateRelation = .same
    public var canAddManualSession: Bool { relationAvailable && !isFutureDate }
    // 副标题「· 今天」只认服务的日期关系，不用设备日期比较。
    public var isSelectedToday: Bool { relationAvailable && selectedRelation == .same }
    public var visibleSessions: [SessionValue] {
        sessions.filter { !pendingDeletion.state.active || $0.id != pendingDeletion.pendingSessionID || $0.isRest != pendingDeletion.state.sessionIsRest }
    }

    public init(history: any FocusHistoryBridgeProtocol, statistics: any StatisticsBridgeProtocol,
                pendingDeletion: PendingDeletionStore, logicalDay: any LogicalDayBridgeProtocol, date: String,
                focus: (any FocusBridgeProtocol)? = nil) {
        self.history = history; statisticsBridge = statistics; self.pendingDeletion = pendingDeletion
        self.logicalDay = logicalDay; self.focus = focus; selectedDate = date
        isFutureDate = false
        do { selectedRelation = try logicalDay.relation(date, to: logicalDay.today); isFutureDate = selectedRelation == .later }
        catch { isFutureDate = false; relationAvailable = false; self.error = error.localizedDescription }
        history.onChanged = { [weak self] in self?.refresh() }
        // 对照 Mac 的 TodayFocusView：完成信号在记录保存后发出，因此专注/休息完成都要立即重读；另有 historyChanged 和回页刷新。
        focus?.onFocusCompleted = { [weak self] _ in self?.refresh() }
        focus?.onRestCompleted = { [weak self] in self?.refresh() }
        logicalDay.onChanged = { [weak self] in self?.logicalDayChanged() }
        statistics.onFailure = { [weak self] in self?.error = $0 }
        refresh()
    }
    public func selectDate(_ date: String) {
        do {
            selectedRelation = try logicalDay.relation(date, to: logicalDay.today)
            isFutureDate = selectedRelation == .later
            selectedDate = date; relationAvailable = true; refresh()
        } catch { relationAvailable = false; self.error = error.localizedDescription }
    }
    public func selectRequestedDate(from shell: ShellStore) {
        guard let date = shell.consumeRequestedFocusDate() else { return }
        selectDate(date)
    }
    public func pageAppeared(shell: ShellStore) {
        if shell.requestedFocusDate != nil { selectRequestedDate(from: shell) }
        else { refresh() }
    }
    // 停在今日时随日界切到新的逻辑今日；正在查看历史日时保留所选日，只重新查询关系。
    public func logicalDayChanged() { selectDate(relationAvailable && selectedRelation == .same ? logicalDay.today : selectedDate) }
    public func adjacentDate(days: Int) -> String? {
        // 翻日使用与统计页相同的 C++ 周期计算；读取失败不改变选中日，不在 Swift 回退计算。
        do { return try logicalDay.period(anchor: selectedDate, range: "day", shift: days, logicalToday: logicalDay.today).start }
        catch { self.error = error.localizedDescription; return nil }
    }
    public func refresh() {
        do {
            let timeline = try history.dayTimeline(date: selectedDate)
            let total = try history.dayTotalDuration(date: selectedDate)
            let day = try statisticsBridge.dayStats(date: selectedDate)
            let options = try history.taskOptions(date: selectedDate)
            let categories = try statisticsBridge.categoryStats(from: selectedDate, to: selectedDate)
            sessions = timeline; totalSeconds = total; statistics = day; taskOptions = options; categoryStatistics = categories
            if relationAvailable { error = "" }
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
        if draft.durationEdited && draft.durationMinutes != Int((Double(original.durationSeconds) / 60.0).rounded()) {
            let seconds = draft.durationMinutes.multipliedReportingOverflow(by: 60)
            guard !seconds.overflow else { error = "时长超出可传递范围"; return false }
            changes.durationSeconds = seconds.partialValue
        }
        if draft.taskID != original.taskID && !draft.isRest { changes.task = draft.taskID > 0 ? .selected(draft.taskID) : SessionTaskChange.none }
        if draft.isRest != original.isRest { changes.isRest = draft.isRest }
        do {
            if original.isRest { try history.updateRestSession(id: original.id, changes: changes) }
            else { try history.updateSession(id: original.id, changes: changes) }
            refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    public func taskOptions(original: SessionValue?) throws -> [SessionTaskOption] {
        var options = try history.taskOptions(date: selectedDate)
        if let original, original.taskID > 0 && !options.contains(where: { $0.taskID == original.taskID }) {
            var old = SessionTaskOption(); old.taskID = original.taskID; old.title = original.taskTitle; options.insert(old, at: 0)
        }
        return options
    }
    @discardableResult public func deleteSession(_ session: SessionValue) -> Bool {
        guard pendingDeletion.requestSession(id: session.id, title: session.taskTitle, isRest: session.isRest) else { return false }
        return true
    }
}
