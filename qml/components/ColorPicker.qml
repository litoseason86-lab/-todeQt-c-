pragma ComponentBehavior: Bound

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
        // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
        required property var modelData
        required property int index

                    id: swatch

                    objectName: "colorSwatch-" + swatch.index
                    Layout.preferredWidth: 48
                    Layout.preferredHeight: 36
                    radius: Theme.radiusSm
                    color: swatch.modelData
                    border.width: root.selectedColor === swatch.modelData ? 3 : 1
                    border.color: root.selectedColor === swatch.modelData ? Theme.ink : Theme.border

                    Behavior on border.width {
                        NumberAnimation {
                            duration: Theme.reduceMotion ? 0 : 150
                            easing.type: Easing.InOutQuad
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor

                        onClicked: {
                            root.selectedColor = swatch.modelData
                            root.colorSelected(swatch.modelData)
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: root.selectedColor === swatch.modelData
                        text: "✓"
                        font.pixelSize: Theme.fontXl
                        font.bold: true
                        // 底是用户挑的科目色，不是主题色：按底色亮度选墨，
                        // 否则夜间主题下深色科目上的对勾会消失。
                        color: Theme.inkOn(swatch.modelData)
                    }
                }
            }
        }
    }
}
