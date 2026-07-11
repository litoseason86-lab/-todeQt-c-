import QtQuick
import ".."

// 背景壁纸层：主题壁纸图片 + 主题 base 兜底色（加载完成前/失败时可见）。
// 主题定义唯一来源 Theme.themes；测试可注入 themeSource。旧 id 由 Theme 迁移。
Item {
    id: root

    property string themeId: "warm"
    property var themeSource: Theme.themes

    readonly property var resolvedTheme: {
        var target = Theme.migrateThemeId(root.themeId)
        var themes = root.themeSource
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === target) {
                return themes[i]
            }
        }
        return themes[0]
    }

    Rectangle {
        objectName: "wallpaperBase"

        anchors.fill: parent
        color: root.resolvedTheme.base
    }

    Image {
        objectName: "wallpaperImage"

        anchors.fill: parent
        source: root.resolvedTheme.wallpaper || ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
    }

    Rectangle {
        objectName: "wallpaperScrim"

        anchors.fill: parent
        // 主题化罩层：无原生 backdrop blur，靠它压住壁纸亮度/细节，
        // 让半透明卡片和文字浮出来。明亮主题为柔白纱，暗色主题为深色纱。
        color: root.resolvedTheme.wallpaperScrim || "transparent"
    }
}
