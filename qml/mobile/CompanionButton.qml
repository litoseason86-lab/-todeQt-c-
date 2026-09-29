pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import ".."
import "../components"

// 伴侣页的按钮：外观沿用 PageActionButton（主/次两档、焦点描边、禁用压淡），
// 区别是内容始终居中、字号大一档——手机上按钮常被拉满一行，图标贴左、文字居中会显得错位。
Button {
    id: root

    property bool primary: false
    property string glyph: ""

    implicitWidth: Math.max(Theme.controlHeightLg, contentRow.implicitWidth + leftPadding + rightPadding)
    implicitHeight: Theme.controlHeightLg
    leftPadding: Theme.space16
    rightPadding: Theme.space16
    focusPolicy: Qt.StrongFocus
    Accessible.name: text

    background: Rectangle {
        radius: Theme.radiusLg
        color: root.primary
               ? (root.down ? Theme.accentFillStrong : Theme.accentFill)
               : (root.down ? Theme.surfaceSunken : Theme.controlSurface)
        border.width: root.visualFocus ? 2 : (root.primary ? 0 : 1)
        border.color: root.visualFocus ? Theme.focusRing : Theme.border
        // 禁用态整体压淡，只靠文字变灰不足以说明「点不动」。
        opacity: root.enabled ? 1 : 0.5
    }

    contentItem: Item {
        implicitWidth: contentRow.implicitWidth
        implicitHeight: contentRow.implicitHeight

        Row {
            id: contentRow

            anchors.centerIn: parent
            spacing: Theme.space8
            // 按下时轻微缩小，与项目其它按钮一致的手感。
            scale: root.down ? 0.96 : 1.0

            Behavior on scale {
                NumberAnimation { duration: Theme.reduceMotion ? 0 : 90; easing.type: Easing.OutQuad }
            }

            GlyphIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.glyph.length > 0
                name: root.glyph
                size: 16
                color: buttonLabel.color
                Accessible.ignored: true
            }

            Text {
                id: buttonLabel

                anchors.verticalCenter: parent.verticalCenter
                text: root.text
                textFormat: Text.PlainText
                color: !root.enabled ? Theme.inkMuted : (root.primary ? Theme.accentFillInk : Theme.ink)
                font.pixelSize: Theme.fontLg
                font.weight: Font.Medium
            }
        }
    }
}
