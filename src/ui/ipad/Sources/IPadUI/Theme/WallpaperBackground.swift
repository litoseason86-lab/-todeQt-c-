import IPadCore
import PTBridge
import SwiftUI
import UIKit

struct WallpaperBackground: View {
    let theme: String
    let enabled: Bool
    @Environment(ShellStore.self) private var shell
    @State private var image: UIImage?
    var body: some View {
        Group {
            if enabled, let image {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
            } else if shell.snapshot.appearance == "theme" { ThemeColors.themeBase(theme) }
            else { Color(uiColor: .systemBackground) }
        }
        .ignoresSafeArea()
        .task(id: enabled ? theme : "") {
            // Qt 已打包的壁纸只读一次，不在每秒计时刷新时反复解码，也不重复打包图片。
            image = enabled ? PTShellBridge.wallpaperData(forTheme: theme).flatMap(UIImage.init(data:)) : nil
        }
    }
}
