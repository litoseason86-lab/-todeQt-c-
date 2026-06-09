import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: root

    title: "添加新任务"
    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property date selectedDate: new Date()

    signal taskAdded(string title, date date, string category)

    function resetFields() {
        titleField.text = ""
        categoryField.text = ""
        errorLabel.text = ""
    }

    onOpened: {
        errorLabel.text = ""
        titleField.forceActiveFocus()
    }

    function submit() {
        var title = titleField.text.trim()
        if (title.length === 0) {
            errorLabel.text = "任务标题不能为空"
            titleField.forceActiveFocus()
            return
        }

        root.taskAdded(title, root.selectedDate, categoryField.text.trim())
        root.resetFields()
        root.close()
    }

    onRejected: root.resetFields()

    background: Rectangle {
        color: "#faf6ee"
        border.color: "#e8dfc8"
        border.width: 1
        radius: 6
    }

    ColumnLayout {
        width: 340
        spacing: 12

        Label {
            text: "任务标题"
            color: "#5d4e37"
            font.pixelSize: 14
        }

        TextField {
            id: titleField

            Layout.fillWidth: true
            placeholderText: "输入任务内容..."
            selectByMouse: true

            background: Rectangle {
                color: "#fffef9"
                border.color: errorLabel.text.length > 0 ? "#c46f5f" : "#e8dfc8"
                border.width: 1
                radius: 4
            }

            onTextEdited: {
                if (text.trim().length > 0) {
                    errorLabel.text = ""
                }
            }

            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        Label {
            text: "科目分类（可选）"
            color: "#5d4e37"
            font.pixelSize: 14
        }

        TextField {
            id: categoryField

            Layout.fillWidth: true
            placeholderText: "如：数学、英语..."
            selectByMouse: true

            background: Rectangle {
                color: "#fffef9"
                border.color: "#e8dfc8"
                border.width: 1
                radius: 4
            }

            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        Label {
            id: errorLabel

            Layout.fillWidth: true
            color: "#9f4d3f"
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            Button {
                id: cancelButton

                text: "取消"
                implicitWidth: 76
                implicitHeight: 34

                background: Rectangle {
                    color: "#e8dfc8"
                    radius: 4
                }

                contentItem: Text {
                    text: cancelButton.text
                    color: "#5d4e37"
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.reject()
            }

            Button {
                id: submitButton

                text: "添加"
                implicitWidth: 76
                implicitHeight: 34

                background: Rectangle {
                    color: "#d4a574"
                    radius: 4
                }

                contentItem: Text {
                    text: submitButton.text
                    color: "#fffef9"
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.submit()
            }
        }
    }
}
