import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

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

    property date selectedDate: {
        // 凌晨日界点前创建的任务仍属于前一逻辑日。
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(hour, new Date())
    }
    property string heading: "添加新任务"
    property var categoryManagerRef: null
    property var categories: []
    // 第一个选项是特殊占位项，表示"不设置科目"，数据库里的 category_id 保持为空。
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
        // 打开时刷新，保证科目管理里的改动不用重启就能显示。
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

        // 这里只传科目 id，由 TaskManager 写入数据库关联字段和兼容旧数据的文本字段。
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
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.surface
            radius: Theme.radiusMd

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: root.heading
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "任务标题"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        TextField {
            id: titleField
            objectName: "titleField"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: 44
            placeholderText: "输入任务内容..."
            selectByMouse: true

            background: Rectangle {
                objectName: "titleFieldBackground"
                color: Theme.surfaceRaised
                border.color: errorLabel.text.length > 0 ? Theme.dangerBorder : (titleField.activeFocus ? Theme.accent : Theme.border)
                border.width: errorLabel.text.length > 0 || titleField.activeFocus ? 2 : 1
                radius: Theme.radiusMd
                layer.enabled: titleField.activeFocus && errorLabel.text.length === 0
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: Theme.accent
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
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "科目分类（可选）"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        ComboBox {
            id: categoryComboBox
            objectName: "categoryComboBox"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: 44
            // 统一左右内边距：左边让文字不贴框（无色点时也不顶边），右边给下拉箭头留位。
            leftPadding: Theme.space12
            rightPadding: 32
            model: root.categoryOptions
            textRole: "name"
            currentIndex: root.categoryOptions.length > 0 ? 0 : -1
            displayText: currentIndex >= 0 && currentIndex < root.categoryOptions.length ? root.categoryOptions[currentIndex].name : "选择科目"

            background: Rectangle {
                objectName: "categoryComboBackground"
                color: categoryComboBox.down || categoryComboBox.pressed ? Theme.accentSoft : (categoryComboBox.hovered ? Theme.surfaceSunken : Theme.surfaceRaised)
                border.color: categoryComboBox.down || categoryComboBox.pressed ? Theme.accent : Theme.border
                border.width: categoryComboBox.down || categoryComboBox.pressed ? 2 : 1
                radius: Theme.radiusMd

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
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
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
                spacing: Theme.space8

                Rectangle {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    radius: 3
                    visible: categoryComboBox.currentIndex >= 0 && categoryComboBox.currentIndex < root.categoryOptions.length && String(root.categoryOptions[categoryComboBox.currentIndex].color || "").length > 0
                    color: visible ? root.categoryOptions[categoryComboBox.currentIndex].color : "transparent"
                }

                Text {
                    Layout.fillWidth: true
                    text: categoryComboBox.displayText
                    color: Theme.ink
                    font.pixelSize: Theme.fontLg
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
            }

            delegate: ItemDelegate {
                id: categoryDelegate
                width: categoryComboBox.width

                contentItem: RowLayout {
                    spacing: Theme.space8

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
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }
                }

                background: Rectangle {
                    color: categoryDelegate.highlighted || categoryDelegate.hovered ? Theme.accentSoft : "transparent"
                }
            }
        }

        Label {
            id: errorLabel

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space8
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space8

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
                    color: cancelButton.pressed ? Theme.glassHover : (cancelButton.hovered ? Theme.glassHover : Theme.glassCard)
                    border.color: cancelButton.hovered || cancelButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

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
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
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
                    color: submitButton.pressed ? Theme.accentStrong : (submitButton.hovered ? Theme.accentStrong : Theme.accent)
                    border.color: submitButton.hovered || submitButton.pressed ? Theme.accentStrong : Theme.accent
                    border.width: 1
                    radius: Theme.radiusMd

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
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
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
