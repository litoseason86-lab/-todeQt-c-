import Foundation
import Observation

// 今日任务页的「搜索 / 批量改期」面板状态。搜索范围、状态筛选、日期是否合法都由服务决定，
// 这里只管结果列表、勾选和提示；对照 Mac 的 TaskToolsDialog。
@MainActor @Observable public final class TodayToolsStore {
    // 数值就是服务 search 的 status 参数：-1 全部、0 未完成、1 已完成。
    public enum Status: Int, CaseIterable, Sendable { case all = -1, unfinished = 0, finished = 1 }
    public var query = ""
    public var status: Status = .all
    public private(set) var rows: [TaskValue] = []
    public private(set) var selectedIDs: [Int] = []
    public private(set) var hasMore = false
    public private(set) var message = ""
    public private(set) var isOpen = false
    @ObservationIgnored private let tasks: any TaskBridgeProtocol
    @ObservationIgnored private let logicalDay: any LogicalDayBridgeProtocol
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    // 每次多取 200 条，上限 10000，与 Mac 一致，避免一次读出整库。
    @ObservationIgnored private var limit = 200
    private static let pageSize = 200, maxLimit = 10000

    public init(tasks: any TaskBridgeProtocol, logicalDay: any LogicalDayBridgeProtocol, pendingDeletion: PendingDeletionStore) {
        self.tasks = tasks; self.logicalDay = logicalDay; self.pendingDeletion = pendingDeletion
    }
    public func open() {
        isOpen = true; message = ""; query = ""; status = .all
        search()
    }
    public func close() { isOpen = false }
    // 新的搜索条件作废旧勾选：旧勾选对应的是上一份结果，留着会改到看不见的任务。
    public func search() {
        limit = Self.pageSize; selectedIDs = []; load()
    }
    public func loadMore() {
        guard limit < Self.maxLimit else { return }
        limit = min(Self.maxLimit, limit + Self.pageSize); load()
    }
    public func toggle(id: Int) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if let index = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: index) } else { selectedIDs.append(id) }
    }
    public func toggleAll() {
        selectedIDs = (!rows.isEmpty && selectedIDs.count == rows.count) ? [] : rows.map(\.id)
    }
    // 逾期口径以服务为准（结转窗口内、不含例行生成的实例），只在当前结果里选。
    public func selectOverdue() {
        do {
            let overdue = Set(try tasks.overdueTasks().map(\.id))
            selectedIDs = rows.map(\.id).filter { overdue.contains($0) }
        } catch { message = error.localizedDescription }
    }
    @discardableResult public func applyDate(_ iso: String) -> Bool {
        guard !selectedIDs.isEmpty else { return false }
        let count = selectedIDs.count
        do { try tasks.move(ids: selectedIDs, date: iso) }
        catch { message = "改期失败，未修改任务，请刷新重试"; return false }
        message = "已将 \(count) 项任务移到 \(iso)"
        // 这批操作到此结束，清空勾选后再重读。
        selectedIDs = []; load()
        return true
    }
    @discardableResult public func copyToToday(id: Int) -> Bool {
        message = ""
        do { try tasks.duplicate(id: id, date: logicalDay.today) }
        catch { message = error.localizedDescription.isEmpty ? "复制失败" : error.localizedDescription; return false }
        message = "已复制到今天，完成状态与计时从零开始"
        load()
        return true
    }
    // 任务变化、待删状态变化时由今日页统一调用；保留仍在结果里的勾选。
    public func reloadIfOpen() { if isOpen { load() } }

    private func load() {
        guard isOpen else { return }
        do {
            let found = try tasks.search(text: query, status: status.rawValue, limit: limit)
            hasMore = found.count >= limit
            // 待删任务先在界面消失；撤销后下一次重读自然恢复。
            let hidden = pendingDeletion.pendingTaskID
            rows = found.filter { $0.id != hidden }
            let visible = Set(rows.map(\.id))
            selectedIDs = selectedIDs.filter { visible.contains($0) }
        } catch { message = error.localizedDescription }
    }
}
