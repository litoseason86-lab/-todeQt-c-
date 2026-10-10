import IPadCore
import SwiftUI

// 专注计时页：所有业务判断在 FocusStore（再往下是 C++ 控制器），这里只放展示和点按接线。
struct FocusView: View {
    @Environment(FocusStore.self) private var store
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if store.freeModeAvailable && store.state != .manualRest {
                    // 平台不开放自由计时时整个控件隐藏，不出现点了必失败的选项。
                    Picker("专注模式", selection: Binding(get: { store.pomodoroModeSelected },
                                                           set: { store.requestModeSwitch(usePomodoro: $0) })) {
                        Text("自由专注").tag(false)
                        Text("番茄专注").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                if store.state != .manualRest { taskHeader }
                if !store.stageText.isEmpty {
                    Text(store.stageText).font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
                }
                if store.state == .workDone || store.state == .breakDone { completionBanner }
                clockArea
                if store.state == .free { Text(store.runningText).font(.body).foregroundStyle(ThemeColors.inkSoft) }
                if store.state == .pomoIdle { FocusDurationPanel(store: store) }
                if !store.errorText.isEmpty {
                    Text(store.errorText).font(.subheadline).foregroundStyle(ThemeColors.danger).multilineTextAlignment(.center)
                }
                controls
            }
            .padding(.horizontal, 24).padding(.vertical, 24)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("专注计时")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.immersiveAvailable {
                    Button { store.enterImmersive() } label: { Label("进入沉浸模式", systemImage: "arrow.up.left.and.arrow.down.right") }
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

    // 空闲时任务名是选择菜单（可选、可新建）；计时中、休息中、刚完成一段时只读。
    @ViewBuilder private var taskHeader: some View {
        VStack(spacing: 8) {
            if store.taskSelectorActive {
                Button { store.openTaskSelector() } label: {
                    HStack {
                        Text(store.selectedTaskTitle.isEmpty ? "选择要专注的任务" : store.selectedTaskTitle)
                            .font(.title3.bold()).lineLimit(2)
                        Image(systemName: "chevron.up.chevron.down").font(.footnote)
                    }
                    .foregroundStyle(store.selectedTaskTitle.isEmpty ? ThemeColors.inkSoft : ThemeColors.ink)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(ThemeColors.accentInk)
                .accessibilityLabel("专注任务，\(store.selectedTaskTitle.isEmpty ? "未选择" : store.selectedTaskTitle)")
                .popover(isPresented: Bindable(store).taskSelectorPresented) {
                    FocusTaskPicker(store: store).presentationCompactAdaptation(.sheet)
                }
            } else {
                Text(store.taskTitleText).font(.title2.bold()).multilineTextAlignment(.center).foregroundStyle(ThemeColors.ink)
            }
            if !store.taskNotes.isEmpty {
                Text(store.taskNotes).font(.callout).foregroundStyle(ThemeColors.inkSoft).lineLimit(3)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var completionBanner: some View {
        Text(store.state == .workDone ? "专注完成" : "休息结束")
            .font(.title3.bold()).foregroundStyle(ThemeColors.inkStrong)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(ThemeColors.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ThemeColors.accent))
    }

    // 自由与主动休息是一行大字时钟，番茄是圆环。
    @ViewBuilder private var clockArea: some View {
        if store.pomodoroModeSelected && store.state != .manualRest {
            FocusRingView(progress: store.ringProgress, tone: ringTone, dimmed: store.ringDimmed,
                          reduceMotion: store.animationsReduced) {
                VStack(spacing: 4) {
                    FocusClockText(text: store.primaryTimeText, size: 52, slim: store.slimClockFont,
                                   color: timeColor)
                    if !store.ringCaption.isEmpty {
                        Text(store.ringCaption).font(.subheadline).foregroundStyle(ThemeColors.inkSoft)
                    }
                }
                .padding(32)
            }
            .frame(maxWidth: 280)
        } else {
            FocusClockText(text: store.primaryTimeText, size: 64, slim: store.slimClockFont, color: ThemeColors.accentInk)
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
        HStack(spacing: 16) {
            switch store.state {
            case .free where !store.snapshot.hasActiveSession:
                prominent("开始专注", enabled: store.canStartFreeFocus) { store.startFreeFocus() }
            case .pomoIdle:
                prominent("开始专注", enabled: store.canStartPomodoro) { store.startPomodoro() }
            case .workDone:
                prominent("开始休息", enabled: true) { store.triggerPrimary() }
                plain("结束") { store.triggerSecondary() }
            case .breakDone:
                prominent("开始专注", enabled: store.primaryButtonEnabled) { store.triggerPrimary() }
                plain("结束") { store.triggerSecondary() }
            default:
                prominent(store.primaryButtonText, enabled: store.primaryButtonEnabled) { store.triggerPrimary() }
                plain(store.secondaryButtonText) { store.triggerSecondary() }
            }
        }
    }
    private func prominent(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 96, minHeight: 36) }
            .buttonStyle(.borderedProminent).tint(ThemeColors.accentFill).disabled(!enabled)
    }
    private func plain(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 96, minHeight: 36) }
            .buttonStyle(.bordered).tint(ThemeColors.inkSoft)
    }
}
