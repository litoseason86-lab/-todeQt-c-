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
                // 定稿：圆环居中，环内时间与一行状态；环下任务名，再下两个圆按钮。
                VStack(spacing: narrow ? 28 : 36) {
                    clockArea(narrow: narrow)
                        .frame(width: narrow ? 280 : 404)
                    VStack(spacing: 20) {
                        taskHeader
                        if !store.errorText.isEmpty {
                            Text(store.errorText).font(.system(size: 15)).foregroundStyle(ThemeColors.danger)
                                .multilineTextAlignment(.center)
                        }
                        controls
                    }
                }
                .padding(.horizontal, narrow ? 16 : 32).padding(.top, narrow ? 24 : 40)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 120), alignment: .top)
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
                HStack(spacing: 6) {
                    Text(store.selectedTaskTitle.isEmpty ? "选择要专注的任务" : store.selectedTaskTitle)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 17, weight: .medium)).foregroundStyle(ThemeColors.ink).frame(minHeight: 44)
            }
            .popover(isPresented: Bindable(store).taskSelectorPresented) {
                FocusTaskPicker(store: store).presentationCompactAdaptation(.sheet)
            }
        } else {
            Text(store.taskTitleText).font(.system(size: 17, weight: .medium))
                .multilineTextAlignment(.center).foregroundStyle(ThemeColors.ink)
        }
    }

    private func clockArea(narrow: Bool) -> some View {
        FocusRingView(progress: store.ringProgress, tone: ringTone, dimmed: store.ringDimmed,
                      reduceMotion: store.animationsReduced, lineWidth: 5, glassFill: false,
                      workColor: ThemeColors.accentInk, trackColor: ThemeColors.borderSubtle) {
            VStack(spacing: 10) {
                FocusClockText(text: store.primaryTimeText,
                               size: (store.pomodoroModeSelected ? 96 : 76) * (narrow ? 0.66 : 1),
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
                        HStack(spacing: 6) {
                            Text(store.modeMenuTitle)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                    }.accessibilityLabel("专注模式与时长，" + store.modeMenuTitle)
                } else {
                    Text(store.compactStageText).font(.system(size: 15)).foregroundStyle(ThemeColors.inkSoft)
                }
            }.padding(28)
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
        default: store.ringDimmed ? ThemeColors.inkSoft : ThemeColors.inkStrong
        }
    }

    @ViewBuilder private var controls: some View {
        if store.taskSelectorActive {
            roundButton("开始专注", icon: "play.fill", primary: true,
                        enabled: store.pomodoroModeSelected ? store.canStartPomodoro : store.canStartFreeFocus) {
                _ = store.startCurrentMode()
            }
        } else {
            HStack(spacing: 24) {
                roundButton(store.primaryButtonText,
                            icon: store.snapshot.running ? "pause.fill" : "play.fill", primary: true,
                            enabled: store.primaryButtonEnabled) { store.triggerPrimary() }
                roundButton(store.secondaryButtonText, icon: "stop.fill", primary: false, enabled: true) {
                    store.triggerSecondary()
                }
            }
        }
    }
    // 定稿：主按钮焦糖实心圆、浅色图标；次按钮浅焦糖圆、焦糖图标；直径 68。
    private func roundButton(_ title: String, icon: String, primary: Bool, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).frame(width: 68, height: 68)
                .foregroundStyle(primary ? ThemeColors.surface : ThemeColors.accentInk)
                .background(primary ? ThemeColors.accentInk : ThemeColors.accentFill, in: Circle())
                .opacity(enabled ? 1 : 0.45)
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
    }
}
