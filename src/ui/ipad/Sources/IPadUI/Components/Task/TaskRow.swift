import IPadCore
import SwiftUI

// 只消费宿主给的操作能力；是否属于今天由宿主服务决定，任务行不比较日期。
// 10-12 对齐提醒事项：点标题就地改标题与备注（InlineTaskEditor，各页共用一份）；ⓘ、左滑「详情」、长按「编辑详情」
// 打开详情浮层（宿主持有「哪一行开着」，行只投影）；左滑「删除」可一滑到底；右滑「完成记录」保留（10-12 用户定）；
// 多选模式下前面换成选择圈、后面的按钮都收起，点整行只切换选中。
struct TaskRow: View {
    let task: TaskValue
    let actions: TaskActions
    var allowsStart = true
    var allowsCompletion = true
    // 正在专注的任务编号（没有会话为 -1）；只传编号，秒数由 FocusElapsedLabel 自己读，整张列表不随计时每秒重算。
    var activeFocusTaskID = -1
    var compactAppearance: Bool? = nil
    // 仪表盘的行不放 ⓘ（定稿 DashboardWide）；开始按钮与今日任务一致：宽窗「▶ 开始」胶囊、窄窗 ▶（10-12 用户要求）。
    var minimal = false
    // 打勾由宿主接管时传（今日页要先登记「停留」再写库）；不传就直接走 TaskActions。
    var onToggleCompletion: (() -> Void)? = nil
    var selectionMode = false
    var selected = false
    var onToggleSelection: (() -> Void)? = nil
    let detailTaskID: Binding<Int?>
    let onCompleteWithNote: () -> Void
    var onReschedule: (() -> Void)?
    var onCopyToToday: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @FocusState private var field: InlineField?
    private enum InlineField { case title, notes }

    private var compact: Bool { compactAppearance ?? (sizeClass == .compact) }
    private var editor: InlineTaskEditor { core.inlineEditor }
    private var editing: Bool { editor.isEditing(task.id) }
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
            leading
            content
            if !selectionMode { trailing }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .onTapGesture { if selectionMode { onToggleSelection?() } }
        .listRowBackground(ThemeColors.surface)
        // 浮层挂在行尾 ⓘ 的位置，箭头指着它；窄窗系统自动改成整页表单。锚点只挂在要打开详情的那一行：
        // 每行常挂一个浮层锚点时，今日任务页随侧栏收放、提示条进出的整页重排明显变重（10-13 真机测速，侧栏收起主线程总忙约 100→280 毫秒）。
        .overlay(alignment: .trailing) {
            TaskDetailAnchor(taskID: task.id, detailTaskID: detailTaskID, core: core, shell: shell)
        }
        .swipeActions(edge: .trailing) {
            if !selectionMode {
                Button(role: .destructive) { act { _ = actions.delete(id: task.id, title: task.title) } } label: {
                    Label("删除", systemImage: "trash")
                }
                .tint(ThemeColors.danger)
                Button { act { detailTaskID.wrappedValue = task.id } } label: { Label("详情", systemImage: "info.circle") }
                    .tint(ThemeColors.inkSoft)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !selectionMode && allowsCompletion && !task.completed {
                Button("完成记录", systemImage: "checkmark") { act(onCompleteWithNote) }.tint(ThemeColors.success)
            }
        }
        .contextMenu { if !selectionMode { menu } }
        .sensoryFeedback(.success, trigger: task.completed)
        .accessibilityAddTraits(selectionMode && selected ? .isSelected : [])
    }

    @ViewBuilder private var leading: some View {
        if selectionMode {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26)).foregroundStyle(selected ? ThemeColors.accentInk : ThemeColors.inkMuted)
                .frame(width: 44, height: 44)
                .accessibilityLabel(selected ? "已选「\(task.title)」" : "选择「\(task.title)」")
        } else if allowsCompletion {
            Button {
                act {
                    // 勾选是一步完成，带记录的完成由右滑或长按打开表单；两条路径共用 TaskActions。
                    if let onToggleCompletion { onToggleCompletion() }
                    else if task.completed { _ = actions.uncomplete(id: task.id) }
                    else { _ = actions.complete(id: task.id, title: task.title) }
                }
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
    }

    @ViewBuilder private var content: some View {
        if editing {
            @Bindable var editor = editor
            VStack(alignment: .leading, spacing: 6) {
                TextField("标题", text: $editor.title)
                    .font(.system(size: 17)).foregroundStyle(ThemeColors.inkStrong)
                    .focused($field, equals: .title)
                    .submitLabel(.done)
                    .onSubmit { field = nil; editor.finish() }
                    .accessibilityLabel("任务标题")
                TextField("备注", text: $editor.notes, axis: .vertical)
                    .font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                    .lineLimit(1...4)
                    .focused($field, equals: .notes)
                    .accessibilityLabel("任务备注")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            // 编辑框随开始编辑才出现，聚焦要等它进了视图树；放在 task 里而不是 onChange，避免聚焦落空。
            .task(id: editor.focusRequested) {
                guard editor.focusRequested, editing else { return }
                field = .title; editor.acknowledgeFocus()
            }
            // 点别处让两个框都失焦就结束编辑；标题与备注之间切换时焦点可能先落空一瞬，所以下一轮再看。
            .onChange(of: field) { _, value in
                guard value == nil else { return }
                Task { @MainActor in
                    if field == nil && editor.isEditing(task.id) { editor.finish() }
                }
            }
        } else {
            let meta = metaText
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 17))
                    .foregroundStyle(task.completed ? ThemeColors.inkMuted : ThemeColors.inkStrong)
                    .strikethrough(task.completed).lineLimit(2)
                if !meta.isEmpty {
                    HStack(spacing: 6) {
                        if !task.categoryName.isEmpty {
                            Circle().fill(TaskCategoryColor.value(task.categoryColor)).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(meta).lineLimit(1)
                    }
                    .font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft)
                }
                if task.completed && !task.completionNote.isEmpty {
                    Text("完成：\(task.completionNote)").font(.system(size: 13)).foregroundStyle(ThemeColors.inkSoft).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !selectionMode { _ = editor.begin(id: task.id) } }
            .accessibilityAction(named: "编辑标题") { _ = editor.begin(id: task.id) }
        }
    }

    @ViewBuilder private var trailing: some View {
        if editing {
            infoButton
        } else {
            if activeFocusTaskID == task.id {
                // 行只投影根计时器的读数，不另设 Timer 或修改正在计时的任务。
                FocusElapsedLabel()
            } else if allowsStart && !task.completed {
                if compact {
                    Button { act { actions.openFocus(id: task.id, title: task.title) } } label: {
                        Image(systemName: "play.fill").font(.system(size: 15)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
                    .accessibilityLabel("开始专注「\(task.title)」")
                } else {
                    Button { act { actions.openFocus(id: task.id, title: task.title) } } label: {
                        Label("开始", systemImage: "play.fill").labelStyle(PillLabelStyle())
                    }
                    .buttonStyle(SoftPillStyle())
                    .accessibilityLabel("开始专注「\(task.title)」")
                }
            }
            if !compact && !minimal { infoButton }
        }
    }
    private var infoButton: some View {
        Button { act { detailTaskID.wrappedValue = task.id } } label: {
            Image(systemName: "info.circle").font(.system(size: 18)).frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless).foregroundStyle(ThemeColors.accentInk)
        .accessibilityLabel("「\(task.title)」的详细信息")
    }

    @ViewBuilder private var menu: some View {
        Button("编辑详情", systemImage: "info.circle") { act { detailTaskID.wrappedValue = task.id } }
        if allowsStart && !task.completed && activeFocusTaskID != task.id {
            Button("开始专注", systemImage: "play.fill") { act { actions.openFocus(id: task.id, title: task.title) } }
        }
        if allowsCompletion && !task.completed {
            Button("完成并写记录", systemImage: "checkmark.circle") { act(onCompleteWithNote) }
        }
        if let onReschedule { Button("改期…", systemImage: "calendar") { act(onReschedule) } }
        if let onCopyToToday { Button("复制到今天", systemImage: "doc.on.doc") { act(onCopyToToday) } }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { act { _ = actions.delete(id: task.id, title: task.title) } }
    }

    // 行上任何别的操作之前先把正在行内编辑的那一行存掉：编辑登记会暂缓列表刷新，不存掉的话打勾、删除都要等编辑结束才看得到。
    private func act(_ body: () -> Void) {
        if editor.isEditing { field = nil; editor.finish() }
        body()
    }
}

// 共享详情编号的读取限于锚点；开关浮层只更新这个子树，行内编辑的视图身份与焦点保持不变。
private struct TaskDetailAnchor: View {
    let taskID: Int
    let detailTaskID: Binding<Int?>
    let core: CoreBridges
    let shell: ShellStore
    private var presented: Binding<Bool> {
        Binding(get: { detailTaskID.wrappedValue == taskID },
                set: { if !$0 && detailTaskID.wrappedValue == taskID { detailTaskID.wrappedValue = nil } })
    }
    var body: some View {
        if detailTaskID.wrappedValue == taskID {
            Color.clear.frame(width: 44, height: 44)
                .popover(isPresented: presented) { TaskDetailSheet(taskID: taskID, core: core, shell: shell) }
                .allowsHitTesting(false)
        }
    }
}

// 「专注中 mm:ss」：每秒变的只有这一小块，单独读专注 Store。
private struct FocusElapsedLabel: View {
    @Environment(FocusStore.self) private var focus
    var body: some View {
        let seconds = focus.snapshot.elapsedSeconds
        Text("专注中 " + String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(ThemeColors.accentInk)
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
