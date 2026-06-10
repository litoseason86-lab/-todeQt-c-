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

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1.0
                duration: 180
                easing.type: Easing.OutQuad
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: 180
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: 160
            easing.type: Easing.InQuad
        }
    }

    Overlay.modal: Rectangle {
        color: "#66000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: 180
                easing.type: Easing.InOutQuad
            }
        }
    }

    property date selectedDate: new Date()
    property string heading: "添加新任务"
    property var categoryManagerRef: null
    property var categories: []
    property var categoryOptions: [{ id: -1, name: "不设置科目", color: "" }]

    signal taskAdded(string title, date date, var category)

    function resetFields() {
        titleField.text = ""
        categoryComboBox.currentIndex = root.categoryOptions.length > 0 ? 0 : -1
        errorLabel.text = ""
    }

    function refreshCategories() {
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            root.categories = root.categoryManagerRef.getAllCategories()
        } else {
            root.categories = []
        }
        root.categoryOptions = [{ id: -1, name: "不设置科目", color: "" }].concat(root.categories)
        if (categoryComboBox.currentIndex < 0 && root.categoryOptions.length > 0) {
            categoryComboBox.currentIndex = 0
        }
    }

    function submit() {
        var title = titleField.text.trim()
        if (title.length === 0) {
            errorLabel.text = "任务标题不能为空"
            titleField.forceActiveFocus()
            return
        }

        var categoryId = categoryComboBox.currentIndex >= 0
                && categoryComboBox.currentIndex < root.categoryOptions.length
                ? Number(root.categoryOptions[categoryComboBox.currentIndex].id || -1)
                : -1
        root.taskAdded(title, root.selectedDate, categoryId)
        root.resetFields()
        root.close()
    }

    Component.onCompleted: root.refreshCategories()

    onOpened: {
        root.refreshCategories()
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

        ComboBox {
            id: categoryComboBox
            objectName: "categoryComboBox"

            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            implicitHeight: 44
            model: root.categoryOptions
            textRole: "name"
            currentIndex: root.categoryOptions.length > 0 ? 0 : -1
            displayText: currentIndex >= 0 && currentIndex < root.categoryOptions.length
                         ? root.categoryOptions[currentIndex].name
                         : "选择科目"

            background: Rectangle {
                color: "#fffef9"
                border.color: categoryComboBox.pressed ? "#d4a574" : "#e8dfc8"
                border.width: 1
                radius: 4
            }

            contentItem: RowLayout {
                spacing: 8

                Rectangle {
                    Layout.leftMargin: 10
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    radius: 3
                    visible: categoryComboBox.currentIndex >= 0
                             && categoryComboBox.currentIndex < root.categoryOptions.length
                             && String(root.categoryOptions[categoryComboBox.currentIndex].color || "").length > 0
                    color: visible ? root.categoryOptions[categoryComboBox.currentIndex].color : "transparent"
                }

                Text {
                    Layout.fillWidth: true
                    text: categoryComboBox.displayText
                    color: "#5d4e37"
                    font.pixelSize: 14
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
            }

            delegate: ItemDelegate {
                width: categoryComboBox.width

                contentItem: RowLayout {
                    spacing: 8

                    Rectangle {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        radius: 3
                        visible: String(modelData.color || "").length > 0
                        color: visible ? modelData.color : "transparent"
                    }

                    Text {
                        Layout.fillWidth: true
                        text: modelData.name || ""
                        color: "#5d4e37"
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }

                background: Rectangle {
                    color: highlighted ? "#f0e6d2" : "transparent"
                }
            }
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
