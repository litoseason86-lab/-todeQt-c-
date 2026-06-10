import QtQuick
import QtQuick.Layouts

Item {
    id: root

    property string selectedColor: "#d4a574"
    readonly property var colors: [
        "#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
        "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"
    ]

    signal colorSelected(string color)

    implicitWidth: 320
    implicitHeight: content.implicitHeight

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 8

        Text {
            Layout.fillWidth: true
            text: "选择颜色"
            font.pixelSize: 13
            color: "#5d4e37"
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 5
            columnSpacing: 8
            rowSpacing: 8

            Repeater {
                model: root.colors

                Rectangle {
                    id: swatch

                    objectName: "colorSwatch-" + index
                    Layout.preferredWidth: 48
                    Layout.preferredHeight: 36
                    radius: 4
                    color: modelData
                    border.width: root.selectedColor === modelData ? 3 : 1
                    border.color: root.selectedColor === modelData ? "#5d4e37" : "#e8dfc8"

                    Behavior on border.width {
                        NumberAnimation {
                            duration: 150
                            easing.type: Easing.InOutQuad
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            root.selectedColor = modelData
                            root.colorSelected(modelData)
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: root.selectedColor === modelData
                        text: "✓"
                        font.pixelSize: 18
                        font.bold: true
                        color: "#fffef9"
                    }
                }
            }
        }
    }
}
