import IPadCore
import SwiftUI

@MainActor struct CategoriesSettings: View {
    @Environment(SettingsCategoryStore.self) private var store
    @State private var deleting: CategoryValue?
    var body: some View {
        @Bindable var store = store
        List {
            ForEach(store.values, id: \.id) { value in
                Button { store.beginEdit(value) } label: {
                    HStack { Text(value.name).foregroundStyle(ThemeColors.ink); Spacer(); Image(systemName: "pencil") }
                }.accessibilityLabel("编辑科目「\(value.name)」")
                .swipeActions {
                    Button("删除", systemImage: "trash", role: .destructive) { deleting = value }
                        .disabled(!store.canDelete(value))
                }
            }
            if !store.errorMessage.isEmpty {
                Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                Button("重试读取科目") { store.reload() }
            }
        }
        .navigationTitle("科目")
        .toolbar { Button("新增科目", systemImage: "plus") { store.beginNew() } }
        .sheet(isPresented: Binding(get: { store.editing }, set: { if !$0 { store.cancel() } })) {
            NavigationStack {
                Form {
                    TextField("科目名称", text: $store.name)
                    Picker("颜色", selection: $store.color) {
                        ForEach(Array(SettingsCategoryStore.colors.enumerated()), id: \.element) { index, color in
                            Text("暖色 \(index + 1)").tag(color)
                        }
                        if !SettingsCategoryStore.colors.contains(store.color) { Text("现有颜色").tag(store.color) }
                    }
                    if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
                }.navigationTitle("科目")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancel() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { _ = store.save() } }
                }
            }.interactiveDismissDisabled()
        }
        .alert("确认删除科目？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let deleting { _ = store.delete(deleting) }; deleting = nil }
        } message: { Text("删除会解除任务、例行、课表和知识缺口的科目关联。") }
        .task { store.reload() }
    }
}

@MainActor struct RoutinesSettings: View {
    @Environment(SettingsRoutineStore.self) private var store
    @State private var deleting: RoutineValue?
    var body: some View {
        @Bindable var store = store
        List {
            ForEach(store.values) { value in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { store.beginEdit(value) } label: {
                            VStack(alignment: .leading) {
                                Text(value.title).foregroundStyle(ThemeColors.ink)
                                Text(value.categoryName.isEmpty ? "不设置科目" : value.categoryName)
                                    .font(.caption).foregroundStyle(ThemeColors.inkMuted)
                            }
                        }.accessibilityLabel("编辑例行「\(value.title)」")
                        Spacer()
                        Toggle("启用例行「\(value.title)」", isOn: Binding(get: { value.active }, set: { store.setActive(value, active: $0) }))
                            .labelsHidden()
                    }
                    Button("重复：" + RoutineWeekdaysFormat.text(value.weekdays)) { store.beginWeekdays(value) }
                }.buttonStyle(.borderless)
                .swipeActions { Button("删除", systemImage: "trash", role: .destructive) { deleting = value } }
            }
            if !store.errorMessage.isEmpty {
                Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                Button("重试读取例行") { store.reload(); store.reloadCategories() }
            }
        }.navigationTitle("每日例行")
        .toolbar { Button("新增例行", systemImage: "plus") { store.beginNew() } }
        .sheet(isPresented: Binding(get: { store.editing }, set: { if !$0 { store.cancel() } })) {
            NavigationStack {
                Form {
                    TextField("标题", text: $store.title)
                    Picker("科目", selection: $store.categoryID) {
                        Text("不设置科目").tag(-1)
                        ForEach(store.categories, id: \.id) { Text($0.name).tag($0.id) }
                        if store.categoryID > 0 && !store.categories.contains(where: { $0.id == store.categoryID }) {
                            Text("当前科目").tag(store.categoryID)
                        }
                    }
                    if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
                }.navigationTitle("每日例行")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancel() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { _ = store.save() } }
                }
            }.interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { store.editingWeekdays }, set: { if !$0 { store.cancel() } })) {
            NavigationStack {
                Form {
                    Section {
                        ForEach(0..<7, id: \.self) { index in
                            Toggle(RoutineWeekdaysFormat.names[index], isOn: Binding(
                                get: { store.weekdays & (1 << index) != 0 },
                                set: { selected in
                                    let bit = 1 << index
                                    store.weekdays = selected ? store.weekdays | bit : store.weekdays & ~bit
                                }))
                        }
                    }
                    Section {
                        Button("每天") { store.weekdays = 127 }
                        Button("工作日") { store.weekdays = 31 }
                        Button("周末") { store.weekdays = 96 }
                    }
                    if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
                }.navigationTitle("重复日")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { store.cancel() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { _ = store.saveWeekdays() } }
                }
            }.interactiveDismissDisabled()
        }
        .alert("确认删除每日例行？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
        }
        .task { store.reload(); store.reloadCategories() }
    }
}
