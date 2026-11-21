import IPadCore
import SwiftUI

// 沉浸全屏：只留计时与必要按钮，隐藏状态栏与系统覆盖层。
struct FocusImmersiveView: View {
    let store: FocusStore
    let shell: ShellStore
    @Environment(\.previewThemeID) private var previewThemeID

    var body: some View {
        ZStack {
            ThemeColors.surface.ignoresSafeArea()
            WallpaperBackground(theme: shell.appearanceState.backgroundTheme, enabled: shell.wallpaperVisible).ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 28) {
                        Text(store.taskTitleText).font(.title2.bold()).foregroundStyle(ThemeColors.ink)
                            .multilineTextAlignment(.center).lineLimit(2)
                        if store.pomodoroModeSelected && store.state != .manualRest {
                            FocusRingView(progress: store.ringProgress, tone: tone, dimmed: store.ringDimmed,
                                          reduceMotion: store.animationsReduced) {
                                VStack(spacing: 4) {
                                    FocusClockText(text: store.primaryTimeText, size: 72, slim: store.slimClockFont,
                                                   color: color)
                                    if !store.ringCaption.isEmpty { Text(store.ringCaption).foregroundStyle(ThemeColors.inkSoft) }
                                }.padding(40)
                            }
                            .frame(maxWidth: 380)
                        } else {
                            FocusClockText(text: store.primaryTimeText, size: 96, slim: store.slimClockFont, color: ThemeColors.accentInk)
                        }
                        if !store.stageText.isEmpty { Text(store.stageText).font(.title3).foregroundStyle(ThemeColors.inkSoft) }
                        HStack(spacing: 16) {
                            Button { store.triggerPrimary() } label: { Text(store.primaryButtonText).frame(minWidth: 96, minHeight: 36) }
                                .buttonStyle(SoftPillStyle())
                                .opacity(store.primaryButtonEnabled ? 1 : 0.45)
                                .disabled(!store.primaryButtonEnabled)
                            Button { store.triggerSecondary() } label: { Text(store.secondaryButtonText).frame(minWidth: 96, minHeight: 36) }
                                .buttonStyle(.bordered).tint(ThemeColors.inkSoft)
                        }
                        if !store.errorText.isEmpty {
                            Text(store.errorText).scaledSystemFont(size: 15).foregroundStyle(ThemeColors.danger)
                                .multilineTextAlignment(.center).lineLimit(2)
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { store.exitImmersive() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("退出沉浸模式")
                }
                Spacer()
            }
            .padding(16)
        }
        .tint(ThemeColors.accentInk)
        // fullScreenCover 位于独立呈现控制器树，需单独挂载主题特征以保持颜色令牌一致。
        .background { ThemeAppearance(themeID: previewThemeID ?? shell.selectedTheme ?? "").frame(width: 0, height: 0) }
        .disabled(shell.operationBlocksUI)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
    private var tone: FocusRingTone {
        switch store.state { case .workDone, .breakDone: .done; case .pomoBreak: .rest; default: .work }
    }
    private var color: Color {
        switch store.state {
        case .workDone, .breakDone: ThemeColors.successInk
        case .pomoBreak: ThemeColors.focusBreakInk
        default: store.ringDimmed ? ThemeColors.inkSoft : ThemeColors.accentInk
        }
    }
}
