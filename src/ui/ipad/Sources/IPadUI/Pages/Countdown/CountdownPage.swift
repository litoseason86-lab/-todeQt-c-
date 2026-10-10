import Foundation
import IPadCore
import SwiftUI

@MainActor struct CountdownPage: View {
    @Environment(CountdownStore.self) private var store
    @Environment(ShellStore.self) private var shell
    @State private var editing: CountdownValue?
    @State private var adding = false
    var body: some View {
        List {
            if !store.errorMessage.isEmpty {
                VStack(alignment: .leading) {
                    Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                    Button("重试") { store.refresh() }
                }
            }
            if let main = store.primary {
                Section("主目标") {
                    Button { editing = main } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(main.name).font(.title2).foregroundStyle(ThemeColors.inkStrong)
                            Text(CountdownFormat.targetDate(main.targetDate)).foregroundStyle(ThemeColors.inkSoft)
                            Text(CountdownFormat.days(main.daysRemaining)).font(.largeTitle.monospacedDigit().bold()).foregroundStyle(ThemeColors.accentInk)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical)
                    }.contextMenu { goalMenu(main) }
                        .swipeActions { Button("删除", role: .destructive) { store.delete(main) } }
                }
            }
            ForEach(store.secondary) { goal in
                Button { editing = goal } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(goal.name).foregroundStyle(ThemeColors.ink)
                            Text(CountdownFormat.targetDate(goal.targetDate)).font(.caption).foregroundStyle(ThemeColors.inkSoft)
                        }
                        Spacer(); Text(CountdownFormat.days(goal.daysRemaining)).monospacedDigit().foregroundStyle(ThemeColors.accentInk)
                    }
                }
                .contextMenu { goalMenu(goal) }
                .swipeActions { Button("删除", role: .destructive) { store.delete(goal) } }
                .listRowBackground(ThemeColors.surface)
            }
        }
        .navigationTitle("目标倒计时")
        .toolbar {
            Button("新增目标", systemImage: "plus") { adding = true }
            Button("记一笔", systemImage: "square.and.pencil") { shell.presentCapture() }
        }
        .sheet(item: $editing) { goal in CountdownSheet(store: store, opened: goal) }
        .sheet(isPresented: $adding) { CountdownSheet(store: store, opened: nil) }
        .onAppear { store.setActive(true) }.onDisappear { store.setActive(false) }
    }
    @ViewBuilder private func goalMenu(_ goal: CountdownValue) -> some View {
        Button("设为主目标") { store.makePrimary(id: goal.id) }.disabled(store.primary?.id == goal.id)
        Button("上移") { store.move(id: goal.id, delta: -1) }.disabled(store.items.first?.id == goal.id)
        Button("下移") { store.move(id: goal.id, delta: 1) }.disabled(store.items.last?.id == goal.id)
        Button("删除", role: .destructive) { store.delete(goal) }
    }
}
@MainActor private struct CountdownSheet: View {
    let store: CountdownStore
    let opened: CountdownValue?
    @Environment(\.dismiss) private var dismiss
    @State private var value: CountdownValue
    init(store: CountdownStore, opened: CountdownValue?) {
        self.store = store; self.opened = opened
        var value = opened ?? CountdownValue()
        // 默认日期由桥接提供逻辑今日，不从 Swift 系统时钟推断业务归属。
        if opened == nil { value.targetDate = CountdownFormat.defaultDate(logicalToday: store.logicalToday) }
        _value = State(initialValue: value)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("目标名称", text: $value.name)
                DatePicker("目标日期", selection: Binding(get: { ContentDateFormat.date(value.targetDate) ?? ContentDateFormat.date(store.logicalToday) ?? Date() }, set: { value.targetDate = ContentDateFormat.isoDate($0) }), displayedComponents: .date)
                if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(ThemeColors.danger) }
            }
            .navigationTitle(opened == nil ? "新增目标" : "编辑目标")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let ok = opened.map { store.save(opened: $0, edited: value) } ?? store.add(name: value.name, date: value.targetDate)
                        if ok { dismiss() }
                    }
                }
            }
        }
    }
}
