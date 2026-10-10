import IPadCore
import SwiftUI

// 沉浸全屏：只留计时与必要按钮，隐藏状态栏与系统覆盖层。
struct FocusImmersiveView: View {
    let store: FocusStore
    let shell: ShellStore

    var body: some View {
        ZStack {
            ThemeColors.surface.ignoresSafeArea()
            WallpaperBackground(theme: shell.snapshot.backgroundTheme, enabled: shell.snapshot.useWallpaper).ignoresSafeArea()
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
                        .buttonStyle(.borderedProminent).tint(ThemeColors.accentFill).disabled(!store.primaryButtonEnabled)
                    Button { store.triggerSecondary() } label: { Text(store.secondaryButtonText).frame(minWidth: 96, minHeight: 36) }
                        .buttonStyle(.bordered).tint(ThemeColors.inkSoft)
                }
            }
            .padding(32)
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
