import QtQuick
import ".."

// 背景壁纸层：主题壁纸图片 + 主题 base 兜底色（加载完成前/失败时可见）。
// 主题定义唯一来源 Theme.themes；测试可注入 themeSource。旧 id 由 Theme 迁移。
Item {
    id: root

    property string themeId: "warm"
    property var themeSource: Theme.themes
    // 沉浸式专注等场景要壁纸原图完整展示，可关掉可读性罩层。
    property bool scrimEnabled: true

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
        // 可读性罩层：无原生 backdrop blur，靠它压住壁纸亮度/细节，
        // 让暖纸半透明面板和文字浮出来。
        color: root.scrimEnabled ? (root.resolvedTheme.wallpaperScrim || "transparent") : "transparent"
    }
}
