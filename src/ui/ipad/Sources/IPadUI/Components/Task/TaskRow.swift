import IPadCore
import SwiftUI

// 只消费宿主给的操作能力；是否属于今天由宿主服务决定，任务行不比较日期。
struct TaskRow: View {
    let task: TaskValue
    let actions: TaskActions
    var allowsStart = true
    var allowsCompletion = true
    var activeFocus: FocusSnapshot? = nil
    var compactAppearance: Bool? = nil
    let onEdit: () -> Void
    let onCompleteWithNote: () -> Void
    var onReschedule: (() -> Void)?
    var onCopyToToday: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var focusSummary: String {
        if task.estimatedMinutes > 0 {
            return DurationFormat.seconds(Double(task.focusedSeconds)) + " / " + DurationFormat.minutes(Double(task.estimatedMinutes))
        }
        if task.focusedSeconds >= 60 { return "已专注 " + DurationFormat.seconds(Double(task.focusedSeconds)) }
        return ""
    }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if allowsCompletion {
                Button {
                    // 勾选是一步完成，带记录的完成由右滑打开表单；两条路径共用 TaskActions。
                    if task.completed { _ = actions.uncomplete(id: task.id) }
                    else { _ = actions.complete(id: task.id, title: task.title) }
                } label: {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(task.completed ? ThemeColors.successInk : ThemeColors.inkMuted)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(task.completed ? "取消完成" : "完成")「\(task.title)」")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.body).foregroundStyle(task.completed ? ThemeColors.inkMuted : ThemeColors.inkStrong)
                    .strikethrough(task.completed).lineLimit(2)
                if !task.categoryName.isEmpty || !focusSummary.isEmpty {
                    HStack(spacing: 6) {
                        if !task.categoryName.isEmpty {
                            Image(systemName: "circle.fill").font(.system(size: 8))
                                .foregroundStyle(TaskCategoryColor.value(task.categoryColor))
                                .accessibilityHidden(true)
                            Text(task.categoryName)
                        }
                        if !focusSummary.isEmpty { Text(focusSummary) }
                    }
                    .font(.caption).foregroundStyle(ThemeColors.inkSoft)
                }
                if !task.notes.isEmpty { Text(task.notes).font(.caption).foregroundStyle(ThemeColors.inkMuted).lineLimit(1) }
                if task.completed && !task.completionNote.isEmpty {
                    Text("完成：\(task.completionNote)").font(.caption).foregroundStyle(ThemeColors.inkSoft).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let activeFocus, activeFocus.hasActiveSession, activeFocus.currentTaskID == task.id {
                // 行只投影根计时器的读数，不另设 Timer 或修改正在计时的任务。
                Text("专注中 " + String(format: "%02d:%02d", activeFocus.elapsedSeconds / 60, activeFocus.elapsedSeconds % 60))
                    .font(.caption.monospacedDigit()).foregroundStyle(ThemeColors.accentInk)
            } else if allowsStart && !task.completed {
                Button { actions.openFocus(id: task.id, title: task.title) } label: {
                    if compactAppearance ?? (sizeClass == .compact) { Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44) }
                    else { Label("开始", systemImage: "play.fill").frame(minHeight: 44) }
                }
                .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
                .accessibilityLabel("开始专注「\(task.title)」")
            }
            if compactAppearance != true {
                Button(action: onEdit) { Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.borderless).foregroundStyle(ThemeColors.inkSoft)
                    .accessibilityLabel("编辑「\(task.title)」")
            }
        }
        .listRowBackground(ThemeColors.surface)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) { _ = actions.delete(id: task.id, title: task.title) }.tint(ThemeColors.danger)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if allowsCompletion && !task.completed {
                Button("完成记录", systemImage: "checkmark") { onCompleteWithNote() }.tint(ThemeColors.success)
            }
        }
        .contextMenu {
            Button("编辑", systemImage: "pencil", action: onEdit)
            if let onReschedule { Button("改期", systemImage: "calendar", action: onReschedule) }
            if let onCopyToToday { Button("复制到今天", systemImage: "doc.on.doc", action: onCopyToToday) }
            Button("删除", systemImage: "trash", role: .destructive) { _ = actions.delete(id: task.id, title: task.title) }
        }
        .sensoryFeedback(.success, trigger: task.completed)
    }
}

// 科目点显示用户保存的科目色，属于数据；其余界面颜色用 ThemeColors，损坏的颜色也回落到语义色。
enum TaskCategoryColor {
    static func value(_ hex: String) -> Color {
        guard hex.count == 7, hex.hasPrefix("#"), let number = UInt32(hex.dropFirst(), radix: 16) else { return ThemeColors.inkSoft }
        return Color(.sRGB, red: Double((number >> 16) & 255) / 255,
                     green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255, opacity: 1)
    }
}
