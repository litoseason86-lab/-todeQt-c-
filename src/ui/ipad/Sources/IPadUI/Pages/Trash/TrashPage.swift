import IPadCore
import SwiftUI

@MainActor struct TrashPage: View {
    @Environment(TrashStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
            List {
                PageHeader(title: store.selecting ? "已选 \(store.selection.count) 项" : "废纸篓", subtitle: "\(store.items.count) 项")
                    .plainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                if !store.loadError.isEmpty {
                    HStack {
                        Label(store.loadError, systemImage: "exclamationmark.triangle").foregroundStyle(ThemeColors.danger)
                        Spacer()
                        Button("重试读取废纸篓") { store.retry() }.buttonStyle(SoftPillStyle())
                    }
                    .plainRow(insets: EdgeInsets(top: 0, leading: 4, bottom: 12, trailing: 4))
                } else if store.loaded && store.items.isEmpty {
                    ContentUnavailableView("废纸篓为空", systemImage: "trash").plainRow()
                }
                ForEach(store.groups) { group in
                    // 定稿组头：左「今天 · 2」，右「还剩 30 天」，13 号半粗；下面一张卡片放这组条目。
                    HStack {
                        Text(TrashFormat.groupHeading(label: group.label, count: group.items.count)).fontWeight(.semibold)
                        Spacer()
                        if !group.remainingLabel.isEmpty { Text(group.remainingLabel) }
                    }
                    .font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                    .plainRow(insets: EdgeInsets(top: 12, leading: 6, bottom: 6, trailing: 6))
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        let selected = store.selecting && store.selection.contains(item.id)
                        VStack(spacing: 0) {
                            if index > 0 { CardDivider() }
                            row(item, wide: wide)
                        }
                        .cardRow(group.items.count == 1 ? .single : index == 0 ? .top : index == group.items.count - 1 ? .bottom : .middle,
                                 fill: selected ? ThemeColors.accentFill : ThemeColors.surface)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !store.selecting && !wide && item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { store.requestRestore(item) }.tint(ThemeColors.accentInk) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !store.selecting { Button("彻底删除", systemImage: "trash", role: .destructive) { store.requestDelete(item) } }
                        }
                        .contextMenu {
                            if !store.selecting {
                                if item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { store.requestRestore(item) } }
                                Button("彻底删除", systemImage: "trash", role: .destructive) { store.requestDelete(item) }
                            }
                        }
                    }
                }
            }
            .modifier(PageListModifier(geometry: geometry, compact: !wide))
        }
        .foregroundStyle(ThemeColors.ink)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            // 10-12 对齐提醒事项：「选择」进多选，批量恢复或彻底删除；彻底删除仍先确认。
            if store.selecting {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(store.allSelected ? "全不选" : "全选") { store.toggleSelectAll() }
                    Button("完成") { store.endSelection() }.fontWeight(.semibold).keyboardShortcut(.escape, modifiers: [])
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("选择") { store.beginSelection() }
                        .disabled(store.items.isEmpty || !store.loadError.isEmpty)
                    Button("清空", role: .destructive) { store.requestEmpty() }
                        .foregroundStyle(ThemeColors.danger)
                        .disabled(store.items.isEmpty || !store.loadError.isEmpty)
                }
            }
        }
        .alert(store.confirmation?.title ?? "", isPresented: Binding(get: { store.confirmation != nil }, set: { _ in }), presenting: store.confirmation) { action in
            Button("取消", role: .cancel) { store.cancelConfirmation() }
            switch action {
            case .restore: Button("恢复") { store.confirmRestore() }
            case .delete: Button("删除", role: .destructive) { store.confirmDelete() }
            case .empty: Button("清空", role: .destructive) { store.confirmEmpty() }
            case .deleteSelection: Button("删除", role: .destructive) { store.confirmDeleteSelection() }
            }
        } message: { action in
            switch action {
            case .restore: Text("恢复「\(store.pendingRestore?.title ?? "")」？")
            case .delete: Text("「\(store.pendingDelete?.title ?? "")」将无法恢复。")
            case .empty: Text("确认框打开时列出的项目将被彻底删除。")
            case .deleteSelection: Text("选中的项目将被彻底删除，无法恢复。")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.selecting {
                SelectionActionBar {
                    SelectionBarButton(title: "恢复", systemImage: "arrow.uturn.backward") { store.restoreSelection() }
                        .disabled(!store.items.contains { store.selection.contains($0.id) && $0.restorable })
                    SelectionBarButton(title: "彻底删除", systemImage: "trash", role: .destructive) { store.requestDeleteSelection() }
                        .disabled(store.selection.isEmpty)
                        .keyboardShortcut(.delete, modifiers: .command)
                }
            } else if !store.actionError.isEmpty || !store.restoredTitle.isEmpty || !store.batchNotice.isEmpty {
                HStack {
                    Text(!store.actionError.isEmpty ? store.actionError
                         : !store.batchNotice.isEmpty ? store.batchNotice : "已恢复「\(store.restoredTitle)」")
                        .foregroundStyle(store.actionError.isEmpty ? ThemeColors.ink : ThemeColors.danger)
                    Spacer()
                    Button("关闭提示", systemImage: "xmark") { store.dismissNotice() }.labelStyle(.iconOnly)
                }.padding().background(ThemeColors.surface)
            }
        }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
    }
    // 定稿行：圆角方块里的类型图标、标题 16、要点 13；宽窗行尾「恢复」胶囊。
    private func row(_ item: TrashItem, wide: Bool) -> some View {
        HStack(spacing: 14) {
            if store.selecting {
                let selected = store.selection.contains(item.id)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24)).foregroundStyle(selected ? ThemeColors.accentInk : ThemeColors.inkMuted)
                    .accessibilityLabel(selected ? "已选" : "未选")
            }
            Image(systemName: icon(item.kind)).font(.system(size: 15)).foregroundStyle(ThemeColors.accentInk)
                .frame(width: 34, height: 34)
                .background(ThemeColors.accentFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "未命名" : item.title).font(.system(size: 16)).foregroundStyle(ThemeColors.inkStrong).lineLimit(2)
                Text(TrashFormat.metaText(item, today: store.today)).font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 0)
            if wide && item.restorable && !store.selecting {
                Button("恢复") { store.requestRestore(item) }.buttonStyle(SoftPillStyle())
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 72)
        .contentShape(Rectangle())
        .onTapGesture { if store.selecting { store.toggleSelection(item.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(store.selecting && store.selection.contains(item.id) ? .isSelected : [])
    }
    private func icon(_ kind: String) -> String {
        switch kind {
        case "task": "checkmark.square"
        case "focus_session": "timer"
        case "rest_session": "pause.circle"
        case "memo": "note.text"
        case "routine": "repeat"
        case "schedule_entry": "calendar"
        case "countdown_goal": "flag"
        case "knowledge_gap": "book"
        default: "archivebox"
        }
    }
}
