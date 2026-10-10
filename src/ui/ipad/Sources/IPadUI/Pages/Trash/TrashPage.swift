import IPadCore
import SwiftUI

@MainActor struct TrashPage: View {
    @Environment(TrashStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("废纸篓").font(.largeTitle.bold())
                    Text("\(store.items.count) 项").font(.subheadline).foregroundStyle(ThemeColors.inkMuted)
                }
                .padding(.horizontal, wide ? 32 : 16)
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
                        Section { ForEach(group.items) { row($0, wide: wide) } } header: {
                            HStack {
                                Text(TrashFormat.groupHeading(label: group.label, count: group.items.count))
                                Spacer()
                                if !group.remainingLabel.isEmpty { Text(group.remainingLabel) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden)
                .contentMargins(.horizontal, wide ? 32 : 16, for: .scrollContent)
            }
            .frame(maxWidth: 900).frame(maxWidth: .infinity).padding(.top, 16)
        }
        .foregroundStyle(ThemeColors.ink)
        .navigationTitle("")
        .toolbar {
            Button("清空", systemImage: "trash") { store.requestEmpty() }
                .disabled(store.items.isEmpty || !store.loadError.isEmpty)
        }
        .alert(store.confirmation?.title ?? "", isPresented: Binding(get: { store.confirmation != nil }, set: { _ in }), presenting: store.confirmation) { action in
            Button("取消", role: .cancel) { store.cancelConfirmation() }
            switch action {
            case .restore: Button("恢复") { store.confirmRestore() }
            case .delete: Button("删除", role: .destructive) { store.confirmDelete() }
            case .empty: Button("清空", role: .destructive) { store.confirmEmpty() }
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
    private func row(_ item: TrashItem, wide: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(item.title.isEmpty ? "未命名" : item.title, systemImage: icon(item.kind)).lineLimit(2)
                Text(TrashFormat.metaText(item, today: store.today)).font(.caption).foregroundStyle(ThemeColors.inkMuted)
            }
            Spacer(minLength: 0)
            if wide && item.restorable {
                Button("恢复") { store.requestRestore(item) }.buttonStyle(.bordered)
            }
        }
        .listRowBackground(ThemeColors.surface)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !wide && item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { store.requestRestore(item) }.tint(ThemeColors.accentInk) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("彻底删除", systemImage: "trash", role: .destructive) { store.requestDelete(item) }
        }
        .contextMenu {
            if item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { store.requestRestore(item) } }
            Button("彻底删除", systemImage: "trash", role: .destructive) { store.requestDelete(item) }
        }
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
