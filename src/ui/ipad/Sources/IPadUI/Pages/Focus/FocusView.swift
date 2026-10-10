import IPadCore
import SwiftUI

// 专注计时页：所有业务判断在 FocusStore（再往下是 C++ 控制器），这里只放展示和点按接线。
struct FocusView: View {
    @Environment(FocusStore.self) private var store
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 700
            ScrollView {
                VStack(spacing: 24) {
                    clockArea
                        .frame(width: narrow ? 260 : 340)
                    if !store.taskSelectorActive {
                        Text(store.compactStageText).font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
                    }
                    taskHeader
                    if !store.errorText.isEmpty {
                        Text(store.errorText).font(.subheadline).foregroundStyle(ThemeColors.danger)
                            .multilineTextAlignment(.center)
                    }
                    controls
                }
                .padding(narrow ? 16 : 32).frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 64))
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.immersiveAvailable {
                    Button { store.enterImmersive() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("进入沉浸模式")
                }
            }
        }
        .onAppear { store.setPageActive(true) }
        .onDisappear { store.setPageActive(false) }
        // 撤销条出现或收起：待删任务的选中项先收起，撤销后还回去。
        .onChange(of: core.pendingDeletion.pendingTaskID, initial: true) { _, _ in store.pendingDeletionChanged() }
        .alert("结束当前计时并切换？", isPresented: .constant(store.switchPrompt != nil), presenting: store.switchPrompt) { prompt in
            Button(prompt.confirmTitle) { store.confirmSwitch() }
            Button("继续当前计时", role: .cancel) { store.cancelSwitch() }
        } message: { prompt in
            Text(prompt.message)
        }
        .sheet(isPresented: Binding(get: { store.longFree != nil }, set: { if !$0 { store.continueLongFree() } })) {
            FocusLongFreeSheet(store: store)
        }
        .fullScreenCover(isPresented: Binding(get: { store.immersiveActive }, set: { if !$0 { store.exitImmersive() } })) {
            FocusImmersiveView(store: store, shell: shell)
        }
    }

    // 空闲任务名使用系统菜单；计时后只读，不能从这里绕过控制器切换会话。
    @ViewBuilder private var taskHeader: some View {
        if store.taskSelectorActive {
            Menu {
                ForEach(store.selectableTasks(), id: \.id) { task in
                    Button(task.title) { store.selectIdleTask(id: task.id, title: task.title) }
                }
                Button("新建并开始", systemImage: "plus") { store.openTaskSelector() }
            } label: {
                Label(store.selectedTaskTitle.isEmpty ? "选择要专注的任务" : store.selectedTaskTitle,
                      systemImage: "chevron.down")
                    .font(.title3).foregroundStyle(ThemeColors.ink).frame(minHeight: 44)
            }
            .popover(isPresented: Bindable(store).taskSelectorPresented) {
                FocusTaskPicker(store: store).presentationCompactAdaptation(.sheet)
            }
        } else {
            Text(store.taskTitleText).font(.title2).multilineTextAlignment(.center).foregroundStyle(ThemeColors.ink)
        }
    }

    private var clockArea: some View {
        FocusRingView(progress: store.ringProgress, tone: ringTone, dimmed: store.ringDimmed,
                      reduceMotion: store.animationsReduced, lineWidth: 3, glassFill: false) {
            VStack(spacing: 12) {
                FocusClockText(text: store.primaryTimeText, size: store.pomodoroModeSelected ? 56 : 42,
                               slim: store.slimClockFont, color: timeColor)
                if store.taskSelectorActive {
                    Menu {
                        ForEach([25, 45, 60], id: \.self) { minutes in
                            Button("番茄 · \(minutes) 分钟") { store.selectModePreset(minutes: minutes) }
                        }
                        if store.freeModeAvailable {
                            Button("自由计时") { store.selectModePreset(minutes: nil) }
                        }
                    } label: {
                        Label(store.modeMenuTitle, systemImage: "chevron.down")
                            .font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
                    }.accessibilityLabel("专注模式与时长，" + store.modeMenuTitle)
                }
            }.padding(24)
        }
    }
    private var ringTone: FocusRingTone {
        switch store.state {
        case .workDone, .breakDone: .done
        case .pomoBreak: .rest
        default: .work
        }
    }
    private var timeColor: Color {
        switch store.state {
        case .workDone, .breakDone: ThemeColors.successInk
        case .pomoBreak: ThemeColors.focusBreakInk
        default: store.ringDimmed ? ThemeColors.inkSoft : ThemeColors.accentInk
        }
    }

    @ViewBuilder private var controls: some View {
        if store.taskSelectorActive {
            roundButton("开始专注", icon: "play.fill", primary: true,
                        enabled: store.pomodoroModeSelected ? store.canStartPomodoro : store.canStartFreeFocus) {
                _ = store.startCurrentMode()
            }
        } else {
            HStack(spacing: 28) {
                roundButton(store.primaryButtonText,
                            icon: store.snapshot.running ? "pause.fill" : "play.fill", primary: true,
                            enabled: store.primaryButtonEnabled) { store.triggerPrimary() }
                roundButton(store.secondaryButtonText, icon: "stop.fill", primary: false, enabled: true) {
                    store.triggerSecondary()
                }
            }
        }
    }
    private func roundButton(_ title: String, icon: String, primary: Bool, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).frame(width: 64, height: 64)
                .foregroundStyle(primary ? ThemeColors.accentInk : ThemeColors.inkSoft)
                .background(primary ? ThemeColors.accentSoft : ThemeColors.surfaceRaised, in: Circle())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
    }
}
