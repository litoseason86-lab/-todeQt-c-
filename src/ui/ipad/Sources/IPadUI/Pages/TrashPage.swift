import IPadCore
import SwiftUI

@MainActor struct TrashPage: View {
    @Environment(CoreBridges.self) private var bridges
    @State private var store: TrashStore?
    @State private var deleteConfirmation = false
    @State private var emptyConfirmation = false

    var body: some View {
        Group {
            if let store {
                content(store)
            } else { ProgressView().task { store = TrashStore(bridge: bridges.trash); store?.activate() } }
        }
        .navigationTitle("废纸篓")
    }

    @ViewBuilder private func content(_ store: TrashStore) -> some View {
        List {
            if !store.loadError.isEmpty {
                Section { VStack(alignment: .leading, spacing: 10) { Label(store.loadError, systemImage: "exclamationmark.triangle").foregroundStyle(ThemeColors.danger); Button("重试") { store.retry() } } }
            } else if store.loaded && store.items.isEmpty {
                ContentUnavailableView("废纸篓为空", systemImage: "trash")
            } else {
                ForEach(store.groups) { group in
                    Section { ForEach(group.items) { item in row(item, store: store) } } header: {
                        HStack { Text("\(group.label) · \(group.items.count)"); Spacer(); if !group.remainingLabel.isEmpty { Text(group.remainingLabel).foregroundStyle(.secondary) } }
                    }
                }
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("清空", systemImage: "trash") { store.requestEmpty(); emptyConfirmation = true }.disabled(store.items.isEmpty || !store.loadError.isEmpty) } }
        .alert("彻底删除", isPresented: $deleteConfirmation) { Button("取消", role: .cancel) { store.cancelDelete() }; Button("删除", role: .destructive) { store.confirmDelete() } } message: { Text(store.pendingDelete.map { "「\($0.title)」将无法恢复。" } ?? "") }
        .alert("清空废纸篓", isPresented: $emptyConfirmation) { Button("取消", role: .cancel) { store.cancelEmpty() }; Button("清空", role: .destructive) { store.confirmEmpty() } } message: { Text("确认框打开时列出的项目将被彻底删除。") }
        .overlay(alignment: .bottom) { if !store.actionError.isEmpty { Text(store.actionError).padding(12).background(.regularMaterial, in: Capsule()).padding() } }
    }

    private func row(_ item: TrashItem, store: TrashStore) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(item.title.isEmpty ? "未命名" : item.title, systemImage: icon(for: item.kind)).lineLimit(1)
            Text(meta(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !item.restorable { Text(item.blockedReason == "needsUpdate" ? "需要更新应用后才能恢复" : "内容已损坏，无法恢复").font(.caption).foregroundStyle(ThemeColors.danger) }
        }
        .swipeActions(edge: .leading) { if item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { store.restore(item) }.tint(ThemeColors.accentInk) } }
        .swipeActions(edge: .trailing) { Button("删除", systemImage: "trash", role: .destructive) { store.requestDelete(item); deleteConfirmation = true } }
        .contextMenu { if item.restorable { Button("恢复", systemImage: "arrow.uturn.backward") { store.restore(item) } }; Button("彻底删除", systemImage: "trash", role: .destructive) { store.requestDelete(item); deleteConfirmation = true } }
    }
    private func icon(for kind: String) -> String { switch kind { case "task": "checkmark.square"; case "focus_session": "timer"; case "rest_session": "pause.circle"; case "memo": "note.text"; case "routine": "repeat"; default: "archivebox" } }
    private func meta(_ item: TrashItem) -> String {
        switch item.kind {
        case "task": return ["任务", item.details.date, item.categoryName].filter { !$0.isEmpty }.joined(separator: " · ")
        case "focus_session": return ["专注记录", item.details.startTime.replacingOccurrences(of: "T", with: " "), item.categoryName].filter { !$0.isEmpty }.joined(separator: " · ")
        case "rest_session": return ["休息记录", item.details.startTime.replacingOccurrences(of: "T", with: " ")].filter { !$0.isEmpty }.joined(separator: " · ")
        case "knowledge_gap": return ["知识缺口", item.details.dueDate].filter { !$0.isEmpty }.joined(separator: " · ")
        case "routine": return ["每日例行", item.categoryName, String(item.details.weekdays)].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return item.kind
        }
    }
}
