import IPadCore
import SwiftUI

// 055-R4 定稿侧栏顶部的「搜索」：任务与知识缺口两张结果卡。匹配与顺序都来自服务（SearchStore），
// 点任务打开任务详情（宽窗是从这一行弹出的浮层，窄窗系统改成整页表单），点缺口跳到知识缺口页并选中它。
@MainActor struct SearchPage: View {
    @Environment(SearchStore.self) private var store
    @Environment(GapStore.self) private var gaps
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @State private var detailTaskID: Int?

    var body: some View {
        @Bindable var store = store
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            List {
                PageHeader(title: "搜索", subtitle: subtitle)
                    .plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 14, trailing: 0))
                if !store.errorMessage.isEmpty {
                    HStack {
                        Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                        Spacer()
                        Button("重试") { store.search() }.buttonStyle(SoftPillStyle())
                    }
                    .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
                }
                if store.searched && store.tasks.isEmpty && store.gaps.isEmpty && store.errorMessage.isEmpty {
                    Text("没有找到「\(store.query.trimmingCharacters(in: .whitespaces))」")
                        .font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                        .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                if !store.tasks.isEmpty {
                    sectionTitle("任务")
                    ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
                        VStack(spacing: 0) {
                            if index > 0 { CardDivider() }
                            Button { detailTaskID = task.id } label: { taskRow(task) }.buttonStyle(.plain)
                                .popover(isPresented: Binding(get: { detailTaskID == task.id },
                                                              set: { if !$0 && detailTaskID == task.id { detailTaskID = nil } })) {
                                    // 详情改过之后结果里的标题、科目要跟着变：浮层收起、详情自己的保存跑完后（下一轮）按当前关键词重搜。
                                    TaskDetailSheet(taskID: task.id, core: core, shell: shell)
                                        .onDisappear { Task { @MainActor in store.search() } }
                                }
                        }
                        .cardRow(position(index, store.tasks.count))
                        .swipeActions(edge: .trailing) {
                            Button { detailTaskID = task.id } label: { Label("详情", systemImage: "info.circle") }.tint(ThemeColors.inkSoft)
                        }
                        .contextMenu {
                            Button("编辑详情", systemImage: "info.circle") { detailTaskID = task.id }
                        }
                    }
                }
                if !store.gaps.isEmpty {
                    sectionTitle("知识缺口")
                    ForEach(Array(store.gaps.enumerated()), id: \.element.id) { index, gap in
                        VStack(spacing: 0) {
                            if index > 0 { CardDivider() }
                            Button { open(gap) } label: { gapRow(gap) }.buttonStyle(.plain)
                        }
                        .cardRow(position(index, store.gaps.count))
                    }
                }
            }
            .modifier(PageListModifier(geometry: geometry, compact: narrow))
        }
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .searchable(text: $store.query, prompt: "搜索任务和知识缺口")
        .onChange(of: store.query) { store.search() }
    }

    private var subtitle: String {
        guard store.searched else { return "" }
        return "任务 \(store.tasks.count) · 知识缺口 \(store.gaps.count)"
    }
    private func position(_ index: Int, _ count: Int) -> CardRowPosition {
        count == 1 ? .single : index == 0 ? .top : index == count - 1 ? .bottom : .middle
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ThemeColors.inkSoft)
            .plainRow(insets: EdgeInsets(top: 12, leading: 6, bottom: 6, trailing: 6))
    }
    private func taskRow(_ task: TaskValue) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20)).foregroundStyle(task.completed ? ThemeColors.accentInk : ThemeColors.accentStrong)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 16)).foregroundStyle(task.completed ? ThemeColors.inkSoft : ThemeColors.inkStrong)
                    .strikethrough(task.completed).lineLimit(2)
                HStack(spacing: 6) {
                    if !task.categoryName.isEmpty {
                        Circle().fill(TaskCategoryColor.value(task.categoryColor)).frame(width: 7, height: 7)
                    }
                    Text([TodayDisplayDate.title(task.date), task.categoryName].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                .font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(minHeight: 64).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    private func gapRow(_ gap: GapValue) -> some View {
        HStack(spacing: 12) {
            Image(systemName: gap.status == 2 ? "checkmark.seal" : "pencil.and.list.clipboard")
                .font(.system(size: 17)).foregroundStyle(ThemeColors.accentInk).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(gap.title).font(.system(size: 16)).foregroundStyle(ThemeColors.inkStrong).lineLimit(2)
                Text([gap.categoryName.isEmpty ? "未分类" : gap.categoryName, gap.status == 2 ? "已解决" : "未解决"].joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(ThemeColors.inkMuted)
        }
        .padding(.horizontal, 16).frame(minHeight: 64).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    // 跳到知识缺口页并显示这一条；搜索前就在缺口页时也会离开搜索（select 总会通知外壳）。
    private func open(_ gap: GapValue) {
        gaps.reveal(gap)
        shell.select(.knowledgeGap)
    }
}
