import QtQuick
import QtQuick.Controls.Basic
import ".."

// 浮动工具栏级玻璃按钮：侧栏收起/展开、浮动条上的重要控制。
// 只用着色玻璃 + 受光棱边，不做实时模糊（模糊留给侧栏条带/专注面板）。
// 按压反馈走 scale（GPU 合成），避免改 width/height 触发布局。
AbstractButton {
    id: root

    property bool reduceMotion: false
    // true：无模糊环境用更实底色，保证图标/字对比度。
    property bool solidFallback: false

    implicitWidth: 36
    implicitHeight: 36
    // 命中区至少接近 36，桌面指针可用；触控场景由外层放大。
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.Button

    scale: root.down ? 0.92 : (root.hovered ? 1.04 : 1.0)
    transformOrigin: Item.Center

    Behavior on scale {
        enabled: !root.reduceMotion
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    background: GlassPanel {
        objectName: "glassToolbarButtonBackground"

        radius: 10
        solidFallback: root.solidFallback
        color: {
            if (root.solidFallback) {
                if (root.down)
                    return Theme.glassSolidAccent
                if (root.hovered || root.visualFocus)
                    return Theme.glassSolidHover
                return Theme.glassSolidCard
            }
            if (root.down)
                return Theme.glassAccent
            if (root.hovered || root.visualFocus)
                return Theme.glassHover
            return Theme.glassCard
        }
        // 浮动钮需要轻微离面；嵌在侧栏标题行里的实例可外层关掉。
        panelShadowEnabled: true
        specularEnabled: true
        bottomRimEnabled: false

        // 焦点环：键盘可达时可见，不单靠 hover。
        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            radius: parent.radius + 2
            color: "transparent"
            border.width: root.visualFocus ? 2 : 0
            border.color: Theme.accent
            visible: root.visualFocus
        }

        Behavior on color {
            enabled: !root.reduceMotion
            ColorAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }
    }

    // 默认 content：sidebar.left 符号；调用方可覆盖 contentItem。
    contentItem: Item {
        implicitWidth: 15
        implicitHeight: 13

        // 图标色用 inkSoft，浅/深底都能辨认，不依赖 accent 当唯一状态。
        readonly property color iconColor: root.enabled ? Theme.inkSoft : Theme.inkMuted

        Rectangle {
            anchors.centerIn: parent
            width: 15
            height: 13
            radius: 2.5
            color: "transparent"
            border.color: parent.iconColor
            border.width: 1.4

            Rectangle {
                width: 4.5
                height: parent.height
                radius: 1.5
                color: parent.border.color
            }
        }
    }
}
