import QtQuick
import ".."

// 背景壁纸层：主题壁纸图片 + 主题 base 兜底色（加载完成前/失败时可见）。
// 主题定义唯一来源 Theme.themes；测试可注入 themeSource。旧 id 由 Theme 迁移。
Item {
    id: root

    property string themeId: "warm"
    property var themeSource: Theme.themes
    // 缩略图传入实际像素尺寸；全屏壁纸保持 0×0，继续按原图解码以避免窗口缩放失真。
    property size requestedSourceSize: Qt.size(0, 0)

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
        sourceSize: root.requestedSourceSize
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
    }
}
