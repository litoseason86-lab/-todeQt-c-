import Foundation
import Observation

@MainActor @Observable public final class TaskCategoryStore {
    public private(set) var values: [CategoryValue] = []
    public private(set) var selectedID = -1
    public var newName = ""
    public var newCategoryPresented = false
    public private(set) var errorMessage = ""
    @ObservationIgnored private let bridge: any CategoryBridgeProtocol
    @ObservationIgnored private var previousChanged: (() -> Void)?
    @ObservationIgnored private var active = false

    // 这是科目数据的默认配色，与 ColorPicker.qml 的暖色阶同源；界面语义色仍由 ThemeColors 提供。
    private static let creationColors = [
        "#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
        "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"
    ]
    public init(bridge: any CategoryBridgeProtocol) { self.bridge = bridge }
    public func open(selectedID: Int) {
        close()
        self.selectedID = selectedID > 0 ? selectedID : -1
        active = true
        // 任务表单只在打开期间订阅，保留并转发宿主已有的科目监听；退出时恢复它。
        // 页面不能同时挂两个任务表单，避免单回调协议出现两个相互覆盖的编辑宿主。
        previousChanged = bridge.onChanged
        let previous = previousChanged
        bridge.onChanged = { [weak self] in previous?(); if self?.active == true { self?.reload() } }
        reload()
    }
    public func close() {
        if active { bridge.onChanged = previousChanged }
        previousChanged = nil; active = false; newCategoryPresented = false
    }
    public func reload() {
        guard active else { return }
        do {
            let loaded = try bridge.allCategories()
            values = loaded
            // 只有成功读取才能认定科目已被删除；失败时保留旧列表与编号，不误归未分类。
            if !loaded.contains(where: { $0.id == selectedID }) { selectedID = -1 }
            errorMessage = ""
        } catch { errorMessage = error.localizedDescription }
    }
    public func select(id: Int) {
        selectedID = values.contains(where: { $0.id == id }) ? id : -1
    }
    public func beginNewCategory() { newName = ""; newCategoryPresented = true; errorMessage = "" }
    public func cancelNewCategory() { newCategoryPresented = false; newName = "" }
    @discardableResult public func createCategory() -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "请输入科目名称"; return false }
        do {
            let id = try bridge.add(name: name, color: Self.creationColors[values.count % Self.creationColors.count])
            guard id > 0 else { errorMessage = "新增科目失败，请重试"; return false }
            // 服务先发变化再返回编号；最后按返回的真实编号选中，不按名称或旧下标反查。
            selectedID = id; newCategoryPresented = false; newName = ""
            // 创建成功不能抹掉同步刷新失败；缺少新条目时保留旧列表与真实编号，显示读取重试。
            if values.contains(where: { $0.id == id }) { errorMessage = "" }
            else { reload() }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
