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
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "目标倒计时")
                    if !store.errorMessage.isEmpty {
                        HStack {
                            Text(store.errorMessage).foregroundStyle(ThemeColors.danger)
                            Spacer()
                            Button("重试") { store.refresh() }.buttonStyle(SoftPillStyle())
                        }
                    }
                    if let main = store.primary {
                        Button { store.requestEdit(main) } label: { primaryCard(main, wide: wide) }
                            .popover(isPresented: editPresented(main)) { CountdownSheet(store: store, opened: main) }
                            .buttonStyle(.plain).contextMenu { goalMenu(main) }
                            .accessibilityElement(children: .combine)
                    }
                    if !store.secondary.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(store.secondary) { goal in
                                if goal.id != store.secondary.first?.id { CardDivider() }
                                Button { store.requestEdit(goal) } label: {
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(goal.name).font(.system(size: 16)).foregroundStyle(ThemeColors.inkStrong)
                                            Text(CountdownFormat.targetDate(goal.targetDate)).font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                                        }
                                        Spacer(minLength: 0)
                                        daysText(goal.daysRemaining, numberSize: 22, unitSize: 13)
                                    }
                                    .padding(.horizontal, 20).frame(minHeight: 68).contentShape(Rectangle())
                                }
                                .popover(isPresented: editPresented(goal)) { CountdownSheet(store: store, opened: goal) }
                                .buttonStyle(.plain).contextMenu { goalMenu(goal) }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
                    }
                }
                .padding(.top, 4).padding(.bottom, 24)
                .frame(maxWidth: Design.contentMaxWidth).frame(maxWidth: .infinity)
            }
            .safeAreaPadding(.horizontal, Design.pagePadding(compact: !wide))
        }
        .foregroundStyle(ThemeColors.ink).navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.requestAdd() } label: { ToolbarTextLabel(title: "新增目标", systemImage: "plus") }
                    .popover(isPresented: Binding(get: { store.form == .add }, set: { if !$0 && store.form == .add { store.dismissForm() } })) {
                        CountdownSheet(store: store, opened: nil)
                    }
            }
        }
        .onAppear { store.setActive(true) }.onDisappear { store.setActive(false) }
    }

    // 新增与编辑都从点的那一处弹出浮层（10-12 对齐提醒事项，浮层不走表单的背景缩放）；窄窗系统改成整页表单。
    private func editPresented(_ goal: CountdownValue) -> Binding<Bool> {
        Binding(get: { if case .edit(let opened) = store.form { return opened.id == goal.id }; return false },
                set: { if !$0, case .edit(let opened) = store.form, opened.id == goal.id { store.dismissForm() } })
    }

    // 定稿主目标卡：左边「主目标」、名称与日期，右边「还有 72 天」（数字 72 号焦糖）；过期写「已过 N 天」。
    private func primaryCard(_ main: CountdownValue, wide: Bool) -> some View {
        let days = main.daysRemaining
        let left = VStack(alignment: .leading, spacing: 6) {
            Text("主目标").font(.system(size: 13, weight: .semibold)).foregroundStyle(ThemeColors.accentInk)
            Text(main.name).font(.system(size: 28, weight: .bold)).foregroundStyle(ThemeColors.inkStrong).lineLimit(2)
            Text(CountdownFormat.targetDate(main.targetDate)).font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
        }
        let right = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(days < 0 ? "已过" : "还有").font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
            Text("\(abs(days))").font(.system(size: wide ? 72 : 56, weight: .bold)).monospacedDigit()
                .foregroundStyle(days < 0 ? ThemeColors.danger : ThemeColors.accentInk)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text("天").font(.system(size: 20, weight: .semibold)).foregroundStyle(ThemeColors.inkStrong)
        }
        return Group {
            if wide {
                HStack(alignment: .center) { left; Spacer(minLength: 16); right }
            } else {
                VStack(alignment: .leading, spacing: 10) { left; right }
            }
        }
        .padding(EdgeInsets(top: 26, leading: 32, bottom: 26, trailing: 32))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.surface, in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
    }

    private func daysText(_ days: Int, numberSize: CGFloat, unitSize: CGFloat) -> some View {
        Group {
            if days < 0 {
                Text(CountdownFormat.days(days)).font(.system(size: 15, weight: .semibold)).foregroundStyle(ThemeColors.danger)
            } else {
                MixedNumberText(parts: [("\(days)", true), ("天", false)], numberSize: numberSize, unitSize: unitSize)
            }
        }
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
            .navigationTitle(opened == nil ? "新增目标" : "编辑目标").sheetChrome()
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
        .frame(idealWidth: 400, idealHeight: 300)
    }
}
