import IPadCore
import PTBridge
import SwiftUI
import UIKit

struct WallpaperBackground: View {
    let theme: String
    let enabled: Bool
    @Environment(ShellStore.self) private var shell
    @Environment(\.previewThemeID) private var previewThemeID
    // 巡检预览主题时一律铺那个主题的壁纸，不读也不改本机设置。
    private var shownTheme: String { previewThemeID ?? theme }
    private var shown: Bool { previewThemeID != nil || enabled }
    var body: some View {
        Group {
            if shown, let image = WallpaperCache.image(for: shownTheme) {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
            } else if previewThemeID != nil || shell.appearanceState.appearance == "theme" { ThemeColors.themeBase(shownTheme) }
            else { Color(uiColor: .systemBackground) }
        }
        .ignoresSafeArea()
    }
}

// 每个页面的外壳都铺一份壁纸（十几份），解码后的图按主题只留一份共用：原来每份视图第一次出现时各解码一遍
// （10-12 测速，切页第一轮比第二轮多出的时间里有一部分在这里）。第一次取时同步解码并预先展开成位图，
// 之后各页直接复用，也不再出现先铺底色、下一帧才换成壁纸的闪动。Qt 已打包的壁纸只读这一次。
@MainActor private enum WallpaperCache {
    private static var images: [String: UIImage] = [:]
    static func image(for theme: String) -> UIImage? {
        if let cached = images[theme] { return cached }
        guard let data = PTShellBridge.wallpaperData(forTheme: theme), let decoded = UIImage(data: data) else { return nil }
        let prepared = decoded.preparingForDisplay() ?? decoded
        images[theme] = prepared
        return prepared
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
