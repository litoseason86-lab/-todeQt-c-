import IPadCore
import SwiftUI

// 搜索与批量改期：结果、勾选和提示在 TodayToolsStore，这里只放控件。
struct TodayToolsSheet: View {
    @Bindable var store: TodayToolsStore
    let today: String
    let actions: TaskActions
    @State private var target = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索全部日期：标题、备注、科目", text: $store.query)
                        .submitLabel(.search).onSubmit { store.search() }
                        .accessibilityLabel("搜索任务")
                    Picker("状态", selection: $store.status) {
                        Text("全部状态").tag(TodayToolsStore.Status.all)
                        Text("未完成").tag(TodayToolsStore.Status.unfinished)
                        Text("已完成").tag(TodayToolsStore.Status.finished)
                    }
                    .onChange(of: store.status) { _, _ in store.search() }
                }
                Section {
                    HStack {
                        Button(store.selectedIDs.count == store.rows.count && !store.rows.isEmpty ? "取消全选" : "全选当前结果") { store.toggleAll() }
                        Spacer()
                        Button("选择逾期") { store.selectOverdue() }
                    }
                    .buttonStyle(.borderless)
                    Text("已选 \(store.selectedIDs.count) / \(store.rows.count) 项").font(.caption).foregroundStyle(ThemeColors.inkSoft)
                }
                Section {
                    ForEach(store.rows, id: \.id) { task in resultRow(task) }
                    if store.rows.isEmpty { Text("没有匹配任务").foregroundStyle(ThemeColors.inkSoft) }
                    if store.hasMore { Button("加载更多（已显示 \(store.rows.count) 项）") { store.loadMore() } }
                }
                Section {
                    DatePicker("移到", selection: $target, displayedComponents: .date)
                    Button("改期 \(store.selectedIDs.count) 项") { _ = store.applyDate(TodayDisplayDate.iso(target)) }
                        .disabled(store.selectedIDs.isEmpty)
                    if !store.message.isEmpty { Text(store.message).font(.callout).foregroundStyle(ThemeColors.inkSoft) }
                }
            }
            .navigationTitle("搜索与批量改期").sheetChrome()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
        .tint(ThemeColors.accentInk)
        .presentationDetents([.large])
        .onAppear { target = TodayDisplayDate.date(today); store.open() }
    }

    private func resultRow(_ task: TaskValue) -> some View {
        let selected = store.selectedIDs.contains(task.id)
        return HStack(spacing: 8) {
            Button { store.toggle(id: task.id) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? ThemeColors.accentInk : ThemeColors.inkMuted)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("选择「\(task.title)」")
            .accessibilityValue(selected ? "已选" : "未选")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).foregroundStyle(ThemeColors.inkStrong).lineLimit(2)
                Text([task.date, task.completed ? "已完成" : "未完成", task.categoryName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(ThemeColors.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !task.completed {
                Button { dismiss(); actions.openFocus(id: task.id, title: task.title) } label: {
                    Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless).accessibilityLabel("开始专注「\(task.title)」")
            }
            Button { _ = store.copyToToday(id: task.id) } label: {
                Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless).accessibilityLabel("复制「\(task.title)」到今天")
        }
    }
}
