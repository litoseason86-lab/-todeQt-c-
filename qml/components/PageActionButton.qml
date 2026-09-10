pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Button {
    id: root

    property bool primary: false
    property string glyph: ""

    implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
    implicitHeight: 40
    leftPadding: Theme.space12
    rightPadding: Theme.space12
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    Accessible.name: text

    background: Rectangle {
        objectName: root.objectName + "Background"
        radius: Theme.radiusLg
        color: root.primary
               ? (root.down || root.hovered ? Theme.accentFillStrong : Theme.accentFill)
               : (root.down || root.hovered ? Theme.surfaceSunken : Theme.controlSurface)
        border.width: root.visualFocus ? 2 : (root.primary ? 0 : 1)
        border.color: root.visualFocus ? Theme.focusRing : Theme.border

        Behavior on color {
            ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
        }
    }

    contentItem: RowLayout {
        spacing: Theme.space8

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
