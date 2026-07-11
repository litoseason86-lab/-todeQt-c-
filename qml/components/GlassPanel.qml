import QtQuick
import QtQuick.Effects
import ".."

// 通用玻璃面板：着色层（自身半透明 color）+ 顶部受光棱边 + 玻璃描边 + 柔和落影。
// 分层参考苹果液态玻璃（折射/着色/高光/内容四层），但全应用约定
// “玻璃 = 半透明色块透出静态壁纸”，面板本身不做实时模糊；
// 需要背景采样的重点控件（仪表盘专注面板）在自己内部叠加采样层。
Rectangle {
    id: root

    // 顶部受光线开关：小尺寸徽章类面板可关掉，避免高光过密。
    property bool specularEnabled: true
    // 落影开关：叠在其它玻璃上的内嵌面板应关掉，防止阴影堆叠发灰。
    property bool panelShadowEnabled: true

    radius: Theme.radiusLg
    color: Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1

    layer.enabled: root.panelShadowEnabled
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: Theme.shadow
        shadowOpacity: 0.08
        shadowBlur: 0.14
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }

    Rectangle {
        objectName: "glassSpecularRim"

        // 受光棱边：中间亮、两端淡出，避开圆角处避免出现硬亮点；
        // 夜间版大幅减弱，白线在暗玻璃上会显脏。
        visible: root.specularEnabled
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.radius + 2
        anchors.rightMargin: root.radius + 2
        height: 1

        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, Theme.darkMode ? 0.20 : 0.65) }
            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
        }
    }
}
