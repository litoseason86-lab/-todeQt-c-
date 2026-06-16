import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Popup {
    id: root

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(480, parent ? Math.max(300, parent.width - 64) : 480)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    property var countdownServiceRef: null
    property int editGoalId: -1
    readonly property bool isEditMode: editGoalId >= 0

    signal goalSaved()

    function dateToInput(value) {
        if (!value) {
            return Qt.formatDate(new Date(), "yyyy-MM-dd");
        }
        return Qt.formatDate(value, "yyyy-MM-dd");
    }

    function openForAdd() {
        editGoalId = -1;
        headingLabel.text = "添加目标";
        nameField.text = "";
        // 默认 30 天后，给用户一个可直接调整的未来日期。
        dateField.text = dateToInput(new Date(Date.now() + 30 * 24 * 60 * 60 * 1000));
        errorLabel.text = "";
        open();
    }

    function openForEdit(goalId, name, targetDate) {
        editGoalId = Number(goalId);
        headingLabel.text = "编辑目标";
        nameField.text = String(name || "");
        dateField.text = dateToInput(targetDate);
        errorLabel.text = "";
        open();
    }

    function parsedDate() {
        var text = dateField.text.trim();
        var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
        if (!match) {
            return null;
        }

        var date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
        if (date.getFullYear() !== Number(match[1]) || date.getMonth() !== Number(match[2]) - 1 || date.getDate() !== Number(match[3])) {
            return null;
        }
        return date;
    }

    function submit() {
        var name = nameField.text.trim();
        if (name.length === 0 || name.length > 50) {
            errorLabel.text = "目标名称长度必须在1-50字符之间";
            nameField.forceActiveFocus();
            return;
        }

        var targetDate = parsedDate();
        if (!targetDate) {
            errorLabel.text = "日期格式必须是 YYYY-MM-DD";
            dateField.forceActiveFocus();
            return;
        }

        if (!root.countdownServiceRef) {
            errorLabel.text = "倒计时服务不可用";
            return;
        }

        var success = root.isEditMode
                ? root.countdownServiceRef.updateGoal(root.editGoalId, name, targetDate)
                : root.countdownServiceRef.addGoal(name, targetDate);
        if (!success) {
            errorLabel.text = "保存失败，请检查输入后重试";
            return;
        }

        root.goalSaved();
        root.close();
    }

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

    onOpened: nameField.forceActiveFocus()

    background: Rectangle {
        id: panel
        objectName: "countdownDialogPanel"

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.surface
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
            Layout.preferredHeight: 48
            color: Theme.surface
            radius: Theme.radiusLg

            Text {
                id: headingLabel
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: "添加目标"
                color: Theme.ink
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "目标名称"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        TextField {
            id: nameField
            objectName: "countdownNameField"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: 44
            placeholderText: "例如：研究生初试"
            selectByMouse: true

            background: Rectangle {
                color: Theme.surfaceRaised
                border.color: errorLabel.text.length > 0 && nameField.activeFocus ? Theme.dangerBorder : (nameField.activeFocus ? Theme.accent : Theme.border)
                border.width: nameField.activeFocus ? 2 : 1
                radius: Theme.radiusMd
            }

            onTextEdited: errorLabel.text = ""
            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "目标日期"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        TextField {
            id: dateField
            objectName: "countdownDateField"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: 44
            placeholderText: "YYYY-MM-DD"
            inputMask: "9999-99-99"
            selectByMouse: true

            background: Rectangle {
                color: Theme.surfaceRaised
                border.color: errorLabel.text.length > 0 && dateField.activeFocus ? Theme.dangerBorder : (dateField.activeFocus ? Theme.accent : Theme.border)
                border.width: dateField.activeFocus ? 2 : 1
                radius: Theme.radiusMd
            }

            onTextEdited: errorLabel.text = ""
            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
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
                text: "取消"
                implicitWidth: 76
                implicitHeight: 44

                background: Rectangle {
                    color: cancelButton.pressed ? Theme.borderSubtle : (cancelButton.hovered ? Theme.surfaceSunken : Theme.surface)
                    border.color: cancelButton.hovered || cancelButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: cancelButton.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.close()
            }

            Button {
                id: submitButton
                objectName: "countdownSubmitButton"
                text: root.isEditMode ? "保存" : "添加"
                implicitWidth: 76
                implicitHeight: 44

                background: Rectangle {
                    color: submitButton.pressed ? Theme.accentStrong : (submitButton.hovered ? Theme.accentStrong : Theme.accent)
                    border.color: submitButton.hovered || submitButton.pressed ? Theme.accentStrong : Theme.accent
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: submitButton.text
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.submit()
            }
        }
    }
}
