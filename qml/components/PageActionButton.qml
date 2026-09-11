pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Button {
    id: root

    property bool primary: false
    // 浮在壁纸上的页头按钮用玻璃底；内容区和弹窗里的按钮保持不透明。
    property bool translucent: false
    property string glyph: ""

    implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
    implicitHeight: Theme.controlHeightMd
    leftPadding: Theme.space12
    rightPadding: Theme.space12
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    Accessible.name: text

    background: Rectangle {
        objectName: root.objectName + "Background"
        radius: Theme.radiusLg
        // 悬停与按下分成两档：合成一档时按下去没有任何反馈，长得像禁用。
        color: root.primary
               ? (root.hovered || root.down ? Theme.accentFillStrong : Theme.accentFill)
               : (root.down ? Theme.surfaceSunken
                            : (root.hovered ? Theme.glassHover
                                            : (root.translucent ? Theme.glassCard : Theme.controlSurface)))
        border.width: root.visualFocus ? 2 : (root.primary ? 0 : 1)
        border.color: root.visualFocus ? Theme.focusRing
                                       : (root.translucent ? Theme.glassBorder : Theme.border)
        // 禁用态整体压淡，只靠文字变灰不足以说明"点不动"。
        opacity: root.enabled ? 1 : 0.5

        Behavior on color {
            ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
        }
    }

    contentItem: RowLayout {
        spacing: Theme.space8
        // 与项目其它主按钮一致的按下手感。
        scale: root.down ? 0.96 : 1.0

        Behavior on scale {
            NumberAnimation { duration: Theme.reduceMotion ? 0 : 90; easing.type: Easing.OutQuad }
        }

        GlyphIcon {
            visible: root.glyph.length > 0
            name: root.glyph
            size: 16
            color: actionLabel.color
            Accessible.ignored: true
        }

        Text {
            id: actionLabel
            objectName: root.objectName + "Label"
            text: root.text
            textFormat: Text.PlainText
            color: !root.enabled ? Theme.inkMuted : (root.primary ? Theme.accentFillInk : Theme.ink)
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
