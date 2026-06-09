import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(280, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    property date selectedDate: new Date()
    property string heading: "添加新任务"

    signal taskAdded(string title, date date, string category)

    function resetFields() {
        titleField.text = ""
        categoryField.text = ""
        errorLabel.text = ""
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

    onOpened: {
        errorLabel.text = ""
        titleField.forceActiveFocus()
    }

    onClosed: root.resetFields()

    background: Rectangle {
        id: panel

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: "#faf6ee"
        border.color: "#e8dfc8"
        border.width: 1
        radius: 6
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: 12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: "#fffef9"
            radius: 6

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 16
                text: root.heading
                color: "#5d4e37"
                font.pixelSize: 15
                font.bold: true
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.topMargin: 4
            text: "任务标题"
            color: "#5d4e37"
            font.pixelSize: 14
        }

        TextField {
            id: titleField
            objectName: "titleField"

            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            implicitHeight: 44
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
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.topMargin: 4
            text: "科目分类（可选）"
            color: "#5d4e37"
            font.pixelSize: 14
        }

        TextField {
            id: categoryField
            objectName: "categoryField"

            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            implicitHeight: 44
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
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            color: "#b24f3d"
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.topMargin: 8
            Layout.bottomMargin: 16
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            Button {
                id: cancelButton
                objectName: "cancelButton"

                text: "取消"
                implicitWidth: 76
                implicitHeight: 44

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

                onClicked: root.close()
            }

            Button {
                id: submitButton
                objectName: "submitButton"

                text: "添加"
                implicitWidth: 76
                implicitHeight: 44

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
