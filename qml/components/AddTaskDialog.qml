import QtQuick
import QtQuick.Controls
import QtQuick.Effects
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
                from: 0.94
                to: 1.0
                duration: 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: 220
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1.0
                to: 0.94
                duration: 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: 220
                easing.type: Easing.InQuad
            }
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
    property var categoryOptions: [
        {
            id: -1,
            name: "不设置科目",
            color: ""
        }
    ]

    signal taskAdded(string title, date date, var category)

    function resetFields() {
        titleField.text = "";
        categoryComboBox.currentIndex = root.categoryOptions.length > 0 ? 0 : -1;
        errorLabel.text = "";
    }

    function refreshCategories() {
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            root.categories = root.categoryManagerRef.getAllCategories();
        } else {
            root.categories = [];
        }
        root.categoryOptions = [
            {
                id: -1,
                name: "不设置科目",
                color: ""
            }
        ].concat(root.categories);
        if (categoryComboBox.currentIndex < 0 && root.categoryOptions.length > 0) {
            categoryComboBox.currentIndex = 0;
        }
    }

    function submit() {
        var title = titleField.text.trim();
        if (title.length === 0) {
            errorLabel.text = "任务标题不能为空";
            titleField.forceActiveFocus();
            return;
        }

        var categoryId = categoryComboBox.currentIndex >= 0 && categoryComboBox.currentIndex < root.categoryOptions.length ? Number(root.categoryOptions[categoryComboBox.currentIndex].id || -1) : -1;
        root.taskAdded(title, root.selectedDate, categoryId);
        root.resetFields();
        root.close();
    }

    Component.onCompleted: root.refreshCategories()

    onOpened: {
        root.refreshCategories();
        errorLabel.text = "";
        titleField.forceActiveFocus();
    }

    onClosed: root.resetFields()

    background: Rectangle {
        id: panel
        objectName: "dialogPanel"

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: "#fffef9"
        border.color: "#e8dfc8"
        border.width: 1
        radius: 8
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: "#000000"
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
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
                font.weight: Font.Bold
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
                objectName: "titleFieldBackground"
                color: "#faf8f3"
                border.color: errorLabel.text.length > 0 ? "#c46f5f" : (titleField.activeFocus ? "#d4a574" : "#e8dfc8")
                border.width: errorLabel.text.length > 0 || titleField.activeFocus ? 2 : 1
                radius: 6
                layer.enabled: titleField.activeFocus && errorLabel.text.length === 0
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: "#d4a574"
                    shadowOpacity: 0.18
                    shadowBlur: 0.18
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            onTextEdited: {
                if (text.trim().length > 0) {
                    errorLabel.text = "";
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
            displayText: currentIndex >= 0 && currentIndex < root.categoryOptions.length ? root.categoryOptions[currentIndex].name : "选择科目"

            background: Rectangle {
                objectName: "categoryComboBackground"
                color: categoryComboBox.down || categoryComboBox.pressed ? "#f0e6d2" : (categoryComboBox.hovered ? "#f5ede3" : "#faf8f3")
                border.color: categoryComboBox.down || categoryComboBox.pressed ? "#d4a574" : "#e8dfc8"
                border.width: categoryComboBox.down || categoryComboBox.pressed ? 2 : 1
                radius: 6

                Behavior on color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            indicator: Text {
                x: categoryComboBox.width - width - 14
                y: Math.round((categoryComboBox.height - height) / 2)
                text: "▾"
                color: "#8b7355"
                font.pixelSize: 12
                rotation: categoryComboBox.down ? 180 : 0
                transformOrigin: Item.Center

                Behavior on rotation {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: RowLayout {
                spacing: 8

                Rectangle {
                    Layout.leftMargin: 10
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    radius: 3
                    visible: categoryComboBox.currentIndex >= 0 && categoryComboBox.currentIndex < root.categoryOptions.length && String(root.categoryOptions[categoryComboBox.currentIndex].color || "").length > 0
                    color: visible ? root.categoryOptions[categoryComboBox.currentIndex].color : "transparent"
                }

                Text {
                    Layout.fillWidth: true
                    Layout.rightMargin: 26
                    text: categoryComboBox.displayText
                    color: "#5d4e37"
                    font.pixelSize: 14
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
            }

            delegate: ItemDelegate {
                id: categoryDelegate
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
                    color: categoryDelegate.highlighted || categoryDelegate.hovered ? "#f0e6d2" : "transparent"
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
                    objectName: "cancelButtonBackground"
                    color: cancelButton.pressed ? "#ded1b5" : (cancelButton.hovered ? "#f5ede3" : "#fffef9")
                    border.color: cancelButton.hovered || cancelButton.pressed ? "#d4a574" : "#e8dfc8"
                    border.width: 1
                    radius: 6

                    Behavior on color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }

                    Behavior on border.color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    objectName: "cancelButtonLabel"
                    text: cancelButton.text
                    color: "#5d4e37"
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    scale: cancelButton.pressed ? 0.96 : 1.0
                    transformOrigin: Item.Center

                    Behavior on scale {
                        NumberAnimation {
                            duration: 90
                            easing.type: Easing.OutQuad
                        }
                    }
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
                    objectName: "submitButtonBackground"
                    color: submitButton.pressed ? "#c99666" : (submitButton.hovered ? "#d9a574" : "#d4a574")
                    border.color: submitButton.hovered || submitButton.pressed ? "#c99666" : "#d4a574"
                    border.width: 1
                    radius: 6

                    Behavior on color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }

                    Behavior on border.color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    objectName: "submitButtonLabel"
                    text: submitButton.text
                    color: "#fffef9"
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    scale: submitButton.pressed ? 0.96 : 1.0
                    transformOrigin: Item.Center

                    Behavior on scale {
                        NumberAnimation {
                            duration: 90
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                onClicked: root.submit()
            }
        }
    }
}
