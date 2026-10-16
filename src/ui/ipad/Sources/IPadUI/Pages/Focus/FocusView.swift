import IPadCore
import SwiftUI

// 专注计时页：所有业务判断在 FocusStore（再往下是 C++ 控制器），这里只放展示和点按接线。
// 10-12 定稿（观感以 docs/业务规则.md「iPad 原生界面」的专注页条目为准）：不加卡片，上中下三段——任务、细线圆环、计时按钮，
// 整组在页面可用区域里上下左右居中，圆环直径随窗口取值，矮窗口改横排（尺寸档位见 FocusPageLayout）；
// 计时进行中 3 秒无操作淡出底部按钮与右上角工具，点屏幕唤醒（何时隐藏由 FocusStore「计时控制自动隐藏」判断）。
struct FocusView: View {
    @Environment(FocusStore.self) private var store
    @Environment(CoreBridges.self) private var core
    @Environment(ShellStore.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    // 本页按钮与工具栏的显隐跟着 store.controlsHidden 走，但要在动画事务里改，淡出淡入才有过渡。
    @State private var chromeHidden = false

    var body: some View {
        // 外层几何读取器留在安全区内，读到的 safeAreaInsets 就是顶栏、标签栏和手势条的高度；
        // 里面的滚动视图只在竖向铺满整页，所以高度按「安全区高 + 上下内边距」算。横向不能铺：
        // iPadOS 26 的侧栏浮在内容上，内容区的左安全区就是侧栏宽度（10-12 真机：铺满后整组按整窗居中，偏左 140）。
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let layout = FocusPageLayout(width: proxy.size.width, height: proxy.size.height + insets.top + insets.bottom,
                                         topInset: insets.top, bottomInset: insets.bottom, compact: sizeClass == .compact,
                                         showsError: !store.errorText.isEmpty)
            ScrollView {
                content(layout)
                    .padding(.top, layout.topPadding).padding(.bottom, layout.bottomPadding)
                    .frame(maxWidth: .infinity, minHeight: layout.regionHeight)
                    .contentShape(Rectangle())
            }
            .scrollBounceBehavior(.basedOnSize)
            // 内容坐标从窗口顶算起，竖向居中只按 FocusPageLayout 的可用区域，不再叠加滚动视图自带的上下安全区内边距。
            .ignoresSafeArea(edges: .vertical)
            // 点屏幕任意处唤醒隐藏的控制；与按钮同时识别，按按钮也算一次操作、从头计时。
            .simultaneousGesture(TapGesture().onEnded { store.wakeControls() })
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .toolbar {
            if store.immersiveAvailable && !chromeHidden {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.enterImmersive() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("进入沉浸模式")
                }
            }
        }
        .onAppear { store.setPageActive(true) }
        .onDisappear {
            store.setPageActive(false)
            shell.focusChromeHidden = false
        }
        .onChange(of: store.controlsAutoHideKey, initial: true) { _, _ in store.syncControlsAutoHide() }
        .onChange(of: voiceOver || switchControl, initial: true) { _, active in store.setAssistiveTechnologyActive(active) }
        .onChange(of: store.controlsHidden, initial: true) { _, hidden in
            // 减少动态效果时直接切换，不做淡出。
            withAnimation(store.animationsReduced ? nil : .easeInOut(duration: 0.35)) {
                chromeHidden = hidden
                shell.focusChromeHidden = hidden
            }
        }
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

    // 竖排三段：任务 44 高、圆环、按钮槽。按钮槽上下高度和任务行相近，圆环几乎正落在整组中线上。
    // 横排：圆环在左，右边一列上面任务、下面按钮，整组仍居中。
    @ViewBuilder private func content(_ layout: FocusPageLayout) -> some View {
        switch layout.axis {
        case .vertical:
            VStack(spacing: 0) {
                taskHeader(layout).frame(height: FocusPageLayout.taskHeight)
                clockArea(layout).padding(.top, layout.gapAbove).padding(.bottom, layout.gapBelow)
                controlsSlot(layout)
                errorBlock(layout)
            }
        case .horizontal:
            HStack(spacing: layout.gapAbove) {
                clockArea(layout)
                VStack(spacing: layout.gapBelow) {
                    taskHeader(layout).frame(height: FocusPageLayout.taskHeight)
                    VStack(spacing: 0) {
                        controlsSlot(layout)
                        errorBlock(layout)
                    }
                }
                .frame(width: FocusPageLayout.sideColumnWidth)
            }
        }
    }
    private func controlsSlot(_ layout: FocusPageLayout) -> some View {
        controls
            .frame(height: layout.controlsHeight)
            .opacity(chromeHidden ? 0 : 1)
            .allowsHitTesting(!chromeHidden)
            .accessibilityHidden(chromeHidden)
    }
    // 错误块参与布局与滚动范围，不随计时按钮隐藏；两行之外的完整内容仍提供给旁白。
    @ViewBuilder private func errorBlock(_ layout: FocusPageLayout) -> some View {
        if layout.errorHeight > 0 {
            Text(store.errorText).scaledSystemFont(size: 15).foregroundStyle(ThemeColors.danger)
                .multilineTextAlignment(.center).lineLimit(2)
                .accessibilityLabel(store.errorText)
                .padding(.top, 12)
                .frame(width: layout.taskMaxWidth, height: layout.errorHeight, alignment: .top)
        }
    }

    // 待机：玻璃胶囊里是任务名，点开选任务；计时后任务由计时器说了算，只读显示，不能从这里绕过控制器切换会话。
    @ViewBuilder private func taskHeader(_ layout: FocusPageLayout) -> some View {
        if store.taskSelectorActive {
            let hasTask = !store.selectedTaskTitle.isEmpty
            Menu {
                ForEach(store.selectableTasks(), id: \.id) { task in
                    Button(task.title) { store.selectIdleTask(id: task.id, title: task.title) }
                }
                Button("新建并开始", systemImage: "plus") { store.openTaskSelector() }
            } label: {
                HStack(spacing: 8) {
                    Text(hasTask ? store.selectedTaskTitle : "选择要专注的任务").lineLimit(1)
                    Image(systemName: "chevron.down").scaledSystemFont(size: 12, weight: .semibold)
                }
                .scaledSystemFont(size: 17, weight: .semibold)
                .foregroundStyle(hasTask ? ThemeColors.inkStrong : ThemeColors.accentInk)
                .padding(.horizontal, 18).frame(height: FocusPageLayout.taskHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .frame(maxWidth: layout.taskMaxWidth)
            .accessibilityLabel(hasTask ? "专注任务，\(store.selectedTaskTitle)" : "选择要专注的任务")
            .popover(isPresented: Bindable(store).taskSelectorPresented) {
                FocusTaskPicker(store: store).presentationCompactAdaptation(.sheet)
            }
        } else {
            Text(store.taskTitleText).scaledSystemFont(size: 17, weight: .semibold).foregroundStyle(ThemeColors.inkStrong)
                .lineLimit(1).frame(maxWidth: layout.taskMaxWidth)
        }
    }

    // 细线环：2 的底轨配 4 的进度弧。自由计时与主动休息是正计时，没有可消退的总量，只留底轨。
    private func clockArea(_ layout: FocusPageLayout) -> some View {
        let countsUp = store.state == .free || store.state == .manualRest
        let longText = store.primaryTimeText.count > 5
        return FocusRingView(progress: countsUp ? 0 : store.ringProgress, tone: ringTone, dimmed: store.ringDimmed,
                             reduceMotion: store.animationsReduced, lineWidth: 4, trackWidth: 2, glassFill: false,
                             workColor: ThemeColors.accentInk, trackColor: ThemeColors.inkStrong.opacity(0.22)) {
            VStack(spacing: layout.ring * 0.035) {
                // 时:分:秒 比 分:秒 多三位，按直径换一档字号，两种写法都落在环内。
                FocusClockText(text: store.primaryTimeText, size: layout.ring * (longText ? 0.15 : 0.23),
                               slim: store.slimClockFont, color: timeColor)
                if store.taskSelectorActive { modeMenu }
                else {
                    Text(store.ringStatusText).scaledSystemFont(size: 15).foregroundStyle(ThemeColors.inkSoft)
                        .lineLimit(1).frame(height: 32)
                }
            }
            .padding(layout.ring * 0.08)
        }
        .frame(width: layout.ring, height: layout.ring)
    }
    private var modeMenu: some View {
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
                Image(systemName: "chevron.down").scaledSystemFont(size: 10, weight: .semibold)
            }
            .scaledSystemFont(size: 15, weight: .medium).foregroundStyle(ThemeColors.inkSoft)
            .padding(.horizontal, 12).frame(height: 32)
            .background(ThemeColors.accentInk.opacity(0.09), in: Capsule())
        }
        .accessibilityLabel("专注模式与时长，" + store.modeMenuTitle)
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

    // 定稿：待机是玻璃胶囊「开始专注」；计时后是两枚细描边圆钮，不抢圆环的视线。
    @ViewBuilder private var controls: some View {
        if store.taskSelectorActive {
            Button(action: startOrPickTask) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").scaledSystemFont(size: 14, weight: .semibold)
                    Text("开始专注")
                }
                .scaledSystemFont(size: 16, weight: .semibold).foregroundStyle(ThemeColors.accentInk)
                .padding(.horizontal, 22).frame(height: 48)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 24) {
                outlineButton(store.primaryButtonText, icon: primaryIcon, enabled: store.primaryButtonEnabled) {
                    store.triggerPrimary()
                }
                outlineButton(store.secondaryButtonText, icon: secondaryIcon, enabled: true) { store.triggerSecondary() }
            }
        }
    }
    // 还没选任务时开始键不置灰：点它直接弹出任务选择，选好再开始。
    private func startOrPickTask() {
        let ready = store.pomodoroModeSelected ? store.canStartPomodoro : store.canStartFreeFocus
        if ready { _ = store.startCurrentMode() } else { store.openTaskSelector() }
    }
    private var primaryIcon: String {
        switch store.state {
        case .workDone, .breakDone: "play.fill"
        default: store.snapshot.running ? "pause.fill" : "play.fill"
        }
    }
    private var secondaryIcon: String { store.state == .pomoBreak ? "forward.fill" : "stop.fill" }
    private func outlineButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).scaledSystemFont(size: 16, weight: .semibold).foregroundStyle(ThemeColors.accentInk)
                .frame(width: 52, height: 52)
                .background(ThemeColors.surface.opacity(0.28), in: Circle())
                .overlay(Circle().strokeBorder(ThemeColors.accentInk.opacity(0.55), lineWidth: 1.5))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
    }
}
