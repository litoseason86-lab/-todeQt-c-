import QtQuick
import QtQuick.Layouts
import ".."

Item {
    id: root

    property string selectedColor: "#e8b04e"
    // 多彩色盘：分类色要在六款主题（含暗色）上都看得清。旧焦糖棕存量值
    // 由 Theme.displayCategoryColor 在渲染时映射到这组新色。
    readonly property var colors: [
        "#e8b04e", "#ef8a65", "#e5638f", "#d9647f", "#c77fd9",
        "#8fbf6f", "#54b3a4", "#5f9ed9", "#8f7ff0", "#8a94a6"
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
