import IPadCore
import SwiftUI

// 时长设置：预设加步进器，写回设置的范围校验在 Store（专注 5–180 分，休息 1–60 分）。
struct FocusDurationPanel: View {
    let store: FocusStore

    var body: some View {
        VStack(spacing: 12) {
            Button {
                store.panelExpanded.toggle()
            } label: {
                Text("专注 \(store.selectedWorkMinutes) 分 · 休息 \(store.selectedBreakMinutes) 分\(store.panelExpanded ? "  ▴" : "  ▾")")
            }
            .buttonStyle(.bordered).tint(ThemeColors.accentInk)
            .accessibilityLabel("时长设置，专注 \(store.selectedWorkMinutes) 分钟，休息 \(store.selectedBreakMinutes) 分钟")
            .accessibilityHint(store.panelExpanded ? "收起" : "展开")
            if store.panelExpanded {
                VStack(spacing: 12) {
                    row("专注", presets: [25, 45, 60], value: store.selectedWorkMinutes, range: 5...180) { store.selectWorkMinutes($0) }
                    row("休息", presets: [5, 10], value: store.selectedBreakMinutes, range: 1...60) { store.selectBreakMinutes($0) }
                    Text("专注时长达到预计用时时自动完成任务 · 不足 \(store.snapshot.minimumValidMinutes) 分钟不计入记录")
                        .font(.footnote).foregroundStyle(ThemeColors.inkSoft).multilineTextAlignment(.center)
                }
                .padding(16)
                .background(ThemeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(ThemeColors.border))
            }
        }
    }

    private func row(_ title: String, presets: [Int], value: Int, range: ClosedRange<Int>,
                     set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(ThemeColors.inkSoft).frame(width: 36, alignment: .trailing)
            ForEach(presets, id: \.self) { minutes in
                Button("\(minutes)") { set(minutes) }
                    .buttonStyle(.bordered)
                    .tint(value == minutes ? ThemeColors.accentInk : ThemeColors.inkSoft)
                    .accessibilityLabel("\(title) \(minutes) 分钟")
            }
            Spacer(minLength: 0)
            Stepper("\(title)分钟数", value: Binding(get: { value }, set: { set($0) }), in: range)
                .labelsHidden()
        }
    }
}

// 任务选择：今日任务（跳过待删项）加「新建并开始」。
struct FocusTaskPicker: View {
    let store: FocusStore


    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section("今日任务") {
                    ForEach(store.selectableTasks(), id: \.id) { task in
                        Button {
                            store.selectIdleTask(id: task.id, title: task.title)
                            store.taskSelectorPresented = false
                        } label: {
                            HStack {
                                Text(task.title).foregroundStyle(task.completed ? ThemeColors.inkMuted : ThemeColors.ink)
                                Spacer()
                                if task.id == store.selectedTaskID { Image(systemName: "checkmark").foregroundStyle(ThemeColors.accentInk) }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
                Section("新建任务") {
                    TextField("任务标题", text: $store.newTaskTitle)
                        .submitLabel(.go)
                        .onSubmit(createAndStart)
                    Button("新建并开始", action: createAndStart)
                        .disabled(store.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("选择任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { store.taskSelectorPresented = false } }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }
    private func createAndStart() {
        let title = store.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // 失败时错误行在专注页显示，选择器也收起，避免遮住它。
        store.taskSelectorPresented = false
        if store.createTaskAndStart(title: title) { store.newTaskTitle = "" }
    }
}

// 超长自由专注的确认：记录 / 修正时长 / 不记录 / 继续计时。关闭等价于继续计时。
struct FocusLongFreeSheet: View {
    let store: FocusStore
    @State private var text = ""
    @State private var initial = ""

    var body: some View {
        NavigationStack {
            Form {
                if let prompt = store.longFree {
                    Section {
                        Text("本次自由计时已持续 \(FocusStore.elapsedLabel(prompt.elapsedSeconds))，超过你设置的 \(prompt.thresholdHours) 小时提醒阈值。是否将这段时间写入专注记录？")
                    }
                    Section {
                        HStack {
                            Text("修正记录时长")
                            Spacer()
                            TextField("分钟", text: $text).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                            Text("分钟")
                        }
                        if !prompt.adjustmentError.isEmpty {
                            Text(prompt.adjustmentError).foregroundStyle(ThemeColors.danger)
                        }
                    } footer: {
                        Text("不修改则保留精确计时；修改后将按整分钟记录。")
                    }
                    Section {
                        Button("记录") { record() }.buttonStyle(.borderedProminent).tint(ThemeColors.accentFill)
                        Button("不记录", role: .destructive) { store.discardLongFree() }
                        Button("继续计时") { store.continueLongFree() }
                    } footer: {
                        Text("不记录会永久删除本次计时；继续计时则保持当前会话。")
                    }
                }
            }
            .navigationTitle("确认自由计时记录")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            guard let prompt = store.longFree else { return }
            initial = String(max(prompt.minimumMinutes, prompt.elapsedSeconds / 60)); text = initial
        }
    }
    private func record() {
        // 没改动就交精确秒数，改过才按整分钟交修正值（校验在 Store）。
        if text == initial { store.recordLongFree() }
        else { store.recordLongFree(correctedMinutes: Int(text.trimmingCharacters(in: .whitespaces))) }
    }
}
