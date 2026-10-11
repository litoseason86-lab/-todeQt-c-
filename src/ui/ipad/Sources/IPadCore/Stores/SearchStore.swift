import Foundation
import Observation

// 055-R4：定稿侧栏顶部的「搜索」。同时查任务和知识缺口，两边都用服务现成的搜索
// （任务同 Mac「搜索与批量改期」，缺口同知识缺口页的搜索框），不另加匹配或排序规则。
@MainActor @Observable public final class SearchStore {
    public var query = ""
    public private(set) var tasks: [TaskValue] = []
    public private(set) var gaps: [GapValue] = []
    public private(set) var errorMessage = ""
    public private(set) var searched = false
    // 任务搜索的 status 参数：-1 全部；缺口列表的状态筛选：-1 全部（服务只认 -2 未解决与具体状态值）。
    private static let allTaskStatus = -1, allGapStatus = -1, taskLimit = 50
    @ObservationIgnored private let taskBridge: any TaskBridgeProtocol
    @ObservationIgnored private let gapBridge: any KnowledgeGapBridging

    public init(tasks: any TaskBridgeProtocol, gaps: any KnowledgeGapBridging) {
        taskBridge = tasks; gapBridge = gaps
    }

    public func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            tasks = []; gaps = []; searched = false; errorMessage = ""
            return
        }
        do {
            let foundTasks = try taskBridge.search(text: text, status: Self.allTaskStatus, limit: Self.taskLimit)
            let foundGaps = try gapBridge.gaps(status: Self.allGapStatus, categoryID: 0, search: text)
            // 两边都成功才替换，失败保留上一次的结果。
            tasks = foundTasks; gaps = foundGaps; searched = true; errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
