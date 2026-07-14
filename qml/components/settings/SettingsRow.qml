import QtQuick
import QtQuick.Layouts
import "../.."

Rectangle {
    id: root

    default property alias trailing: trailingSlot.data
    property string label: ""
    property string caption: ""
    property bool compact: false

    Layout.fillWidth: true
    implicitHeight: compact ? 76 : 68
    color: "transparent"

    RowLayout {
        anchors.fill: parent
        spacing: Theme.space16

        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 120
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
