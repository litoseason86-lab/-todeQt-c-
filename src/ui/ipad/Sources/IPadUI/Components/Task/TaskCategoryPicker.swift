import IPadCore
import SwiftUI

struct TaskCategoryPicker: View {
    @Bindable var store: TaskCategoryStore
    private var selectedName: String {
        store.values.first { $0.id == store.selectedID }?.name ?? (store.selectedID > 0 ? "科目读取失败" : "不设置科目")
    }
    var body: some View {
        LabeledContent("科目") {
            Menu {
                Button("不设置科目") { store.select(id: -1) }
                ForEach(store.values, id: \.id) { category in
                    Button { store.select(id: category.id) } label: {
                        if category.id == store.selectedID { Label(category.name, systemImage: "checkmark") }
                        else { Text(category.name) }
                    }
                }
                Divider()
                // 新建是独立菜单动作，永远不把 -2 哨兵当成实际选择或交给任务写入。
                Button("新建科目…", systemImage: "plus") { store.beginNewCategory() }
            } label: { Text(selectedName).frame(minHeight: 44) }
            .accessibilityLabel("科目：\(selectedName)")
        }
        .sheet(isPresented: $store.newCategoryPresented) {
            TaskCategoryCreationSheet(store: store)
        }
        if !store.errorMessage.isEmpty {
            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
            Button("重试读取科目") { store.reload() }
        }
    }
}

private struct TaskCategoryCreationSheet: View {
    @Bindable var store: TaskCategoryStore
    var body: some View {
        NavigationStack {
            Form {
                TextField("科目名称", text: $store.newName).accessibilityLabel("科目名称")
                if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle("新建科目").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancelNewCategory() } }
                ToolbarItem(placement: .confirmationAction) { Button("新建") { _ = store.createCategory() } }
            }
        }
        .tint(ThemeColors.accentInk)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(!store.newName.isEmpty)
    }
}
