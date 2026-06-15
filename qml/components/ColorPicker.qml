import QtQuick
import QtQuick.Layouts
import ".."

Item {
    id: root

    property string selectedColor: "#d4a574"
    // 色板与迁移生成色保持同一组，避免旧科目和新建科目视觉割裂。
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
        spacing: Theme.space8

        Text {
            Layout.fillWidth: true
            text: "选择颜色"
            font.pixelSize: Theme.fontMd
            color: Theme.ink
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 5
            columnSpacing: Theme.space8
            rowSpacing: Theme.space8

            Repeater {
                model: root.colors

                Rectangle {
                    id: swatch

                    objectName: "colorSwatch-" + index
                    Layout.preferredWidth: 48
                    Layout.preferredHeight: 36
                    radius: Theme.radiusSm
                    color: modelData
                    border.width: root.selectedColor === modelData ? 3 : 1
                    border.color: root.selectedColor === modelData ? Theme.ink : Theme.border

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
                        font.pixelSize: Theme.fontXl
                        font.bold: true
                        color: Theme.surface
                    }
                }
            }
        }
    }
}
