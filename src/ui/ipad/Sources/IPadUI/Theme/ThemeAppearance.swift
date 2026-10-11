import IPadCore
import SwiftUI
import UIKit

// 窗口级主题特征由系统沿 UIKit 视图树传播，动态 UIColor（随环境求值的颜色）据此选择系统或主题令牌。
// affectsColorAppearance 确保浅色主题之间切换也失效重绘，不靠重建页面丢失编辑状态。
struct IPadThemeTrait: UITraitDefinition {
    static let defaultValue = ""
    static let affectsColorAppearance = true
}

struct ThemeAppearance: UIViewControllerRepresentable {
    let themeID: String
    func makeUIViewController(context: Context) -> ThemeTraitController { ThemeTraitController() }
    func updateUIViewController(_ controller: ThemeTraitController, context: Context) {
        controller.themeID = themeID
        controller.applyTheme()
    }
}

final class ThemeTraitController: UIViewController {
    var themeID = ""
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyTheme()
    }
    func applyTheme() {
        // 只改承载本原生视图的控制器树，不取 UIApplication 的其它场景，不触及 Qt/iPhone 窗口。
        guard var host = parent else { return }
        while let parent = host.parent { host = parent }
        host.traitOverrides[IPadThemeTrait.self] = themeID
    }
}
