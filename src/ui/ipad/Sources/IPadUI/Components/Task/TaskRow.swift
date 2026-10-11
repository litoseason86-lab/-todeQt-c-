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
    // 仪表盘的行只放圆圈、标题、科目行和 ▶（定稿 DashboardWide），宽窗也不放「开始」胶囊与 ⓘ。
    var minimal = false
    let onEdit: () -> Void
    let onCompleteWithNote: () -> Void
    var onReschedule: (() -> Void)?
    var onCopyToToday: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { minimal || (compactAppearance ?? (sizeClass == .compact)) }
    private var focusSummary: String {
        if task.estimatedMinutes > 0 {
            return DurationFormat.seconds(Double(task.focusedSeconds)) + " / " + DurationFormat.minutes(Double(task.estimatedMinutes))
        }
        if task.focusedSeconds >= 60 { return "已专注 " + DurationFormat.seconds(Double(task.focusedSeconds)) }
        return ""
    }
    // 定稿 .meta：科目 · 已专注 / 预计 · 备注，一行写完。
    private var metaText: String {
        [task.categoryName, focusSummary, task.notes].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if allowsCompletion {
                Button {
                    // 勾选是一步完成，带记录的完成由右滑打开表单；两条路径共用 TaskActions。
                    if task.completed { _ = actions.uncomplete(id: task.id) }
                    else { _ = actions.complete(id: task.id, title: task.title) }
                } label: {
                    Group {
                        if task.completed {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 26))
                                .foregroundStyle(ThemeColors.accentInk)
                        } else {
                            Circle().strokeBorder(ThemeColors.accentStrong, lineWidth: 2).frame(width: 26, height: 26)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(task.completed ? "取消完成" : "完成")「\(task.title)」")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 17))
                    .foregroundStyle(task.completed ? ThemeColors.inkMuted : ThemeColors.inkStrong)
                    .strikethrough(task.completed).lineLimit(2)
                if !metaText.isEmpty {
                    HStack(spacing: 6) {
                        if !task.categoryName.isEmpty {
                            Circle().fill(TaskCategoryColor.value(task.categoryColor)).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(metaText).lineLimit(1)
                    }
                    .font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                }
                if task.completed && !task.completionNote.isEmpty {
                    Text("完成：\(task.completionNote)").font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let activeFocus, activeFocus.hasActiveSession, activeFocus.currentTaskID == task.id {
                // 行只投影根计时器的读数，不另设 Timer 或修改正在计时的任务。
                Text("专注中 " + String(format: "%02d:%02d", activeFocus.elapsedSeconds / 60, activeFocus.elapsedSeconds % 60))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(ThemeColors.accentInk)
            } else if allowsStart && !task.completed {
                if compact {
                    Button { actions.openFocus(id: task.id, title: task.title) } label: {
                        Image(systemName: "play.fill").font(.system(size: 15)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
                    .accessibilityLabel("开始专注「\(task.title)」")
                } else {
                    Button { actions.openFocus(id: task.id, title: task.title) } label: {
                        Label("开始", systemImage: "play.fill").labelStyle(PillLabelStyle())
                    }
                    .buttonStyle(SoftPillStyle())
                    .accessibilityLabel("开始专注「\(task.title)」")
                }
            }
            if !compact {
                Button(action: onEdit) { Image(systemName: "info.circle").font(.system(size: 18)).frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
                    .accessibilityLabel("编辑「\(task.title)」")
            }
        }
        .frame(minHeight: 64)
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

// 胶囊里的图标与文字：图标小一号，间距 6（定稿 .start 内 svg 14px、gap 6px）。
struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 12)); configuration.title }
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
