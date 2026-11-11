import Foundation
import Observation

// 055-R4：定稿侧栏顶部的「搜索」。同时查任务和知识缺口，两边都用服务现成的搜索
// （任务同 Mac「搜索与批量改期」，缺口同知识缺口页的搜索框），不另加匹配或排序规则。
@MainActor @Observable public final class SearchStore {
    public var query = ""
    private var rawTasks: [TaskValue] = []
    // 共享待删槽是可观察的展示状态；只变化槽位时也立即隐藏或恢复搜索行，不重搜、不重排。
    public var tasks: [TaskValue] { rawTasks.filter { $0.id != pendingDeletion.pendingTaskID } }
    public private(set) var gaps: [GapValue] = []
    public private(set) var errorMessage = ""
    public private(set) var searched = false
    // 任务搜索的 status 参数：-1 全部；缺口列表的状态筛选：-1 全部（服务只认 -2 未解决与具体状态值）。
    private static let allTaskStatus = -1, allGapStatus = -1, taskLimit = 50
    @ObservationIgnored private let pendingDeletion: PendingDeletionStore
    @ObservationIgnored private let taskBridge: any TaskBridgeProtocol
    @ObservationIgnored private let gapBridge: any KnowledgeGapBridging

    @ObservationIgnored private let categoryBridge: (any CategoryBridgeProtocol)?

    public init(tasks: any TaskBridgeProtocol, gaps: any KnowledgeGapBridging, pendingDeletion: PendingDeletionStore, categories: (any CategoryBridgeProtocol)? = nil) {
        self.pendingDeletion = pendingDeletion
        taskBridge = tasks; gapBridge = gaps; categoryBridge = categories
        // 任务或缺口在别处改动（详情里改名、删除、同步进来）后按当前查询重读，结果不停在旧数据上。
        // 科目也要听：任务搜索同时匹配科目名，结果行显示科目名和颜色，而改科目只发科目变更。
        // 这几个适配器是本 Store 独占的实例，占用它们的变更回调不影响其它页面。
        tasks.onChanged = { [weak self] in self?.dataChanged() }
        gaps.onChanged = { [weak self] in self?.dataChanged() }
        categories?.onChanged = { [weak self] in self?.dataChanged() }
    }
    // 还没搜过（或查询已清空）就不读。
    private func dataChanged() { if searched { search() } }

    public func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            rawTasks = []; gaps = []; searched = false; errorMessage = ""
            return
        }
        do {
            let foundTasks = try taskBridge.search(text: text, status: Self.allTaskStatus, limit: Self.taskLimit)
            let foundGaps = try gapBridge.gaps(status: Self.allGapStatus, categoryID: 0, search: text)
            // 两边都成功才替换，失败保留上一次的结果。
            rawTasks = foundTasks; gaps = foundGaps; searched = true; errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
