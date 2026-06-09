import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    property string title: ""
    property string value: "0"
    property string unit: ""
    property string subtitle: ""

    implicitWidth: 190
    implicitHeight: 104
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 6

        Text {
            Layout.fillWidth: true
            text: root.title
            font.pixelSize: 13
            font.bold: true
            color: "#8b7355"
            elide: Text.ElideRight
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                id: valueText

                Layout.fillWidth: true
                text: root.value
                font.pixelSize: 28
                font.bold: true
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 18
                color: "#5d4e37"
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }

            Text {
                visible: root.unit.length > 0
                text: root.unit
                font.pixelSize: 13
                color: "#8b7355"
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.subtitle.length > 0
            text: root.subtitle
            font.pixelSize: 12
            color: "#8b7355"
            elide: Text.ElideRight
        }
    }
}
