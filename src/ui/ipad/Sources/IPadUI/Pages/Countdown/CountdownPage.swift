import Foundation
import IPadCore
import SwiftUI

@MainActor struct CountdownPage: View {
    @Environment(CountdownStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标倒计时").font(.largeTitle.bold())
                        Text("\(store.items.count) 个目标").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                    }
                    if !store.errorMessage.isEmpty {
                        VStack(alignment: .leading) {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Button("重试") { store.refresh() }
                        }
                    }
                    if let main = store.primary {
                        Button { store.requestEdit(main) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("主目标").font(.subheadline).foregroundStyle(ThemeColors.accentInk)
                                Text(main.name).font(.title2.bold()).foregroundStyle(ThemeColors.inkStrong)
                                Text(CountdownFormat.targetDate(main.targetDate)).foregroundStyle(ThemeColors.inkSoft)
                                Text(CountdownFormat.days(main.daysRemaining))
                                    .font(.system(size: wide ? 64 : 48, weight: .bold, design: .rounded))
                                    .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1).foregroundStyle(ThemeColors.accentInk)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(wide ? 28 : 20)
                            .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain).contextMenu { goalMenu(main) }
                        .accessibilityElement(children: .combine)
                    }
                    if !store.secondary.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(store.secondary) { goal in
                                Button { store.requestEdit(goal) } label: {
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(goal.name).font(.headline).foregroundStyle(ThemeColors.ink)
                                            Text(CountdownFormat.targetDate(goal.targetDate)).font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
                                        }
                                        Spacer(minLength: 0)
                                        Text(CountdownFormat.days(goal.daysRemaining)).font(.title3.bold())
                                            .monospacedDigit().foregroundStyle(ThemeColors.accentInk)
                                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain).contextMenu { goalMenu(goal) }
                                .accessibilityElement(children: .combine)
                                if goal.id != store.secondary.last?.id { Divider().overlay(ThemeColors.borderSubtle).padding(.horizontal, 20) }
                            }
                        }.background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .frame(maxWidth: 900).frame(maxWidth: .infinity)
                .padding(.horizontal, wide ? 32 : 16).padding(.vertical, 16)
            }
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbar {
            Button("新增目标", systemImage: "plus") { store.requestAdd() }
        }
        .sheet(item: Binding(get: { store.form }, set: { if $0 == nil { store.dismissForm() } })) { intent in
            CountdownSheet(store: store, opened: intent.opened)
        }
        .onAppear { store.setActive(true) }.onDisappear { store.setActive(false) }
    }
    @ViewBuilder private func goalMenu(_ goal: CountdownValue) -> some View {
        Button("设为主目标") { store.makePrimary(id: goal.id) }.disabled(store.primary?.id == goal.id)
        Button("上移") { store.move(id: goal.id, delta: -1) }.disabled(store.items.first?.id == goal.id)
        Button("下移") { store.move(id: goal.id, delta: 1) }.disabled(store.items.last?.id == goal.id)
        Button("编辑", systemImage: "pencil") { store.requestEdit(goal) }
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
