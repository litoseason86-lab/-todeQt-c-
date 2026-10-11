import IPadCore
import PTBridge
import SwiftUI
import UIKit

struct WallpaperBackground: View {
    let theme: String
    let enabled: Bool
    @Environment(ShellStore.self) private var shell
    @Environment(\.previewThemeID) private var previewThemeID
    @State private var image: UIImage?
    // 巡检预览主题时一律铺那个主题的壁纸，不读也不改本机设置。
    private var shownTheme: String { previewThemeID ?? theme }
    private var shown: Bool { previewThemeID != nil || enabled }
    var body: some View {
        Group {
            if shown, let image {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
            } else if previewThemeID != nil || shell.snapshot.appearance == "theme" { ThemeColors.themeBase(shownTheme) }
            else { Color(uiColor: .systemBackground) }
        }
        .ignoresSafeArea()
        .task(id: shown ? shownTheme : "") {
            // Qt 已打包的壁纸只读一次，不在每秒计时刷新时反复解码，也不重复打包图片。
            image = shown ? PTShellBridge.wallpaperData(forTheme: shownTheme).flatMap(UIImage.init(data:)) : nil
        }
    }
}

// 055-R4 巡检用：在巡检窗口里临时套用某个主题看效果，平时为 nil，不影响正常界面，也不写设置。
private struct PreviewThemeKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var previewThemeID: String? {
        get { self[PreviewThemeKey.self] }
        set { self[PreviewThemeKey.self] = newValue }
    }
}
