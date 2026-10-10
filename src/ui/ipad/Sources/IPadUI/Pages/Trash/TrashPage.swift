import IPadCore
import SwiftUI

@MainActor struct TrashPage: View {
    @Environment(TrashStore.self) private var store
    @State private var confirmation: Confirmation?
    private enum Confirmation {
        case restore, delete, empty
        var title: String {
            switch self { case .restore: "恢复项目？"; case .delete: "彻底删除？"; case .empty: "清空废纸篓？" }
        }
    }
    var body: some View {
        List {
            if !store.loadError.isEmpty {
                Section {
                    Label(store.loadError, systemImage: "exclamationmark.triangle").foregroundStyle(ThemeColors.danger)
                    Button("重试读取废纸篓") { store.retry() }
                }
            } else if store.loaded && store.items.isEmpty {
                ContentUnavailableView("废纸篓为空", systemImage: "trash")
            }
            ForEach(store.groups) { group in
                Section { ForEach(group.items) { row($0) } } header: {
                    HStack {
                        Text(TrashFormat.groupHeading(label: group.label, count: group.items.count))
                        Spacer()
                        if !group.remainingLabel.isEmpty { Text(group.remainingLabel) }
                    }
                }
            }
        }.navigationTitle("废纸篓")
        .toolbar {
            Button("清空", systemImage: "trash") { store.requestEmpty(); confirmation = .empty }
                .disabled(store.items.isEmpty || !store.loadError.isEmpty)
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { _ in }), presenting: confirmation) { action in
            Button("取消", role: .cancel) { cancelConfirmation() }
            switch action {
            case .restore: Button("恢复") { store.confirmRestore(); confirmation = nil }
            case .delete: Button("删除", role: .destructive) { store.confirmDelete(); confirmation = nil }
            case .empty: Button("清空", role: .destructive) { store.confirmEmpty(); confirmation = nil }
            }
        } message: { action in
            switch action {
            case .restore: Text("恢复「\(store.pendingRestore?.title ?? "")」？")
            case .delete: Text("「\(store.pendingDelete?.title ?? "")」将无法恢复。")
            case .empty: Text("确认框打开时列出的项目将被彻底删除。")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.actionError.isEmpty || !store.restoredTitle.isEmpty {
                HStack {
                    Text(store.actionError.isEmpty ? "已恢复「\(store.restoredTitle)」" : store.actionError)
                        .foregroundStyle(store.actionError.isEmpty ? ThemeColors.ink : ThemeColors.danger)
                    Spacer()
                    Button("关闭提示", systemImage: "xmark") { store.dismissNotice() }.labelStyle(.iconOnly)
                }.padding().background(ThemeColors.surface)
            }
        }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
    }
    private func cancelConfirmation() {
        store.cancelRestore(); store.cancelDelete(); store.cancelEmpty(); confirmation = nil
    }
    private func row(_ item: TrashItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(item.title.isEmpty ? "未命名" : item.title, systemImage: icon(item.kind)).lineLimit(2)
            Text(TrashFormat.metaText(item, today: store.today)).font(.caption).foregroundStyle(ThemeColors.inkMuted)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { requestRestore(item) }.tint(ThemeColors.accentInk) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", systemImage: "trash", role: .destructive) { store.requestDelete(item); confirmation = .delete }
        }
        .contextMenu {
            if item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { requestRestore(item) } }
            Button("彻底删除", systemImage: "trash", role: .destructive) { store.requestDelete(item); confirmation = .delete }
        }
    }
    private func requestRestore(_ item: TrashItem) { store.requestRestore(item); confirmation = .restore }
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
