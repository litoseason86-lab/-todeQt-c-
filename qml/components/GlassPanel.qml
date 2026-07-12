import QtQuick
import QtQuick.Effects
import ".."

// 液态玻璃 QML 实现（着色 + 受光棱边 + 描边 + 可选落影）。
// 对应 liquid-glass 四层里的 Layer1 着色 / Layer2 高光 / Layer3 内容承载；
// Layer0 背景采样模糊不在本组件内做——全应用约定：
//   实时模糊只允许：侧栏条带、仪表盘专注面板（重要控制）、（可选）全屏弹层。
//   普通内容卡只用本组件半透明色块透壁纸，保证 60FPS。
// 不支持模糊时：调用方把 color 换成 Theme.glassSolid* 降级令牌即可。
Rectangle {
    id: root

    // 顶部受光棱边：徽章/小按钮可关，避免高光过密。
    property bool specularEnabled: true
    // 底部微弱暗边：增强玻璃厚度感；嵌套面板建议关掉。
    property bool bottomRimEnabled: false
    // 落影：叠在其它玻璃上时关掉，防阴影堆叠发灰。
    property bool panelShadowEnabled: true
    // 降级：无 GPU/关模糊时用更实的底色，保证 ink 字色对比度。
    property bool solidFallback: false

    radius: Theme.radiusLg
    color: root.solidFallback ? Theme.glassSolidCard : Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1

    // 落影走 MultiEffect 单次阴影 pass；不可见时关掉 layer，避免 FBO 常驻。
    layer.enabled: root.panelShadowEnabled && root.visible && root.opacity > 0.01
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: Theme.shadow
        shadowOpacity: Theme.darkMode ? 0.22 : 0.08
        shadowBlur: 0.14
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }

    // Layer2 高光：顶部受光棱边（中间亮、两端淡，避开圆角硬亮点）。
    Rectangle {
        objectName: "glassSpecularRim"
        z: 2

        visible: root.specularEnabled
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.radius + 2
        anchors.rightMargin: root.radius + 2
        height: 1
        // 装饰层不抢无障碍焦点。
        Accessible.ignored: true

        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
            GradientStop {
                position: 0.5
                color: Qt.rgba(1, 1, 1, Theme.darkMode ? 0.20 : 0.65)
            }
            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
        }
    }

    // 底部弱暗棱：模拟玻璃厚度，不替代顶部高光。
    Rectangle {
        objectName: "glassBottomRim"
        z: 2

        visible: root.bottomRimEnabled
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.radius + 2
        anchors.rightMargin: root.radius + 2
        height: 1
        Accessible.ignored: true
        color: Qt.rgba(0, 0, 0, Theme.darkMode ? 0.28 : 0.06)
    }
}
