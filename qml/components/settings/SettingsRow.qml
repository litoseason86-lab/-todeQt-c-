import QtQuick
import QtQuick.Layouts
import ".."
import "../.."

Rectangle {
    id: root

    default property alias trailing: trailingSlot.data
    property string label: ""
    property string caption: ""
    // 行首图标：iconName 走 GlyphIcon 线性图标；iconText 走文字字形（如「Aa」）。
    property string iconName: ""
    property string iconText: ""
    property bool compact: false

    Layout.fillWidth: true
    implicitHeight: compact ? 76 : 68
    color: "transparent"

    RowLayout {
        anchors.fill: parent
        spacing: Theme.space12

        Rectangle {
            visible: root.iconName.length > 0 || root.iconText.length > 0
            Layout.preferredWidth: 30
            Layout.preferredHeight: 30
            Layout.alignment: Qt.AlignVCenter
            radius: Theme.radiusSm + 2
            color: Theme.accentSoft

            GlyphIcon {
                anchors.centerIn: parent
                visible: root.iconName.length > 0
                name: root.iconName
                size: 17
                color: Theme.accentInk
            }

            Text {
                anchors.centerIn: parent
                visible: root.iconText.length > 0
                text: root.iconText
                color: Theme.accentInk
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 110
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: root.label
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                visible: root.caption.length > 0
                text: root.caption
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }
        }

        RowLayout {
            id: trailingSlot

            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            spacing: Theme.space8
        }
    }
}
