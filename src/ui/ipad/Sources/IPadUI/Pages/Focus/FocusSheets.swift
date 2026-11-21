import IPadCore
import SwiftUI

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
            .navigationTitle("选择任务").sheetChrome()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { store.taskSelectorPresented = false } }
            }
        }
        .tint(ThemeColors.accentInk)
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
                        Button { record() } label: { Text("记录").foregroundStyle(ThemeColors.accentFillInk) }
                            .buttonStyle(.borderedProminent).tint(ThemeColors.accentFill)
                        Button("不记录", role: .destructive) { store.discardLongFree() }
                        Button("继续计时") { store.continueLongFree() }
                    } footer: {
                        Text("不记录会永久删除本次计时；继续计时则保持当前会话。")
                    }
                }
            }
            .navigationTitle("确认自由计时记录").sheetChrome()
        }
        .tint(ThemeColors.accentInk)
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
