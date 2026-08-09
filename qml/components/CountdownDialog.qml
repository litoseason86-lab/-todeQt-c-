pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

Popup {
    id: root

    // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    // 下拉面板与选项行；不接管的话夜间主题下是白底配米白字。
    palette.window: Theme.inputPopupSurface
    palette.mid: Theme.inputPopupBorder
    palette.light: Theme.inputPopupHighlight
    palette.midlight: Theme.inputPopupHighlight
    // 未自定义 background 的下拉框/输入框，闭合状态的底与文字也得接管。
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    // GroupBox 标题、勾选框文字，以及没显式写 color 的 Label 都吃这个。
    palette.windowText: Theme.controlInk

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(480, parent ? Math.max(300, parent.width - 64) : 480)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    property var countdownServiceRef: null
    // 仅测试注入；生产为空时读取真实时间。
    property var logicalNowProvider: null
    property int editGoalId: -1
    readonly property bool isEditMode: editGoalId >= 0

    signal goalSaved()

    function logicalToday() {
        // qmllint disable use-proper-function
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint enable use-proper-function
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(hour, now)
    }

    function dateToInput(value) {
        return Qt.formatDate(value ? value : root.logicalToday(), "yyyy-MM-dd");
    }

    function openForAdd() {
        editGoalId = -1;
        headingLabel.text = "添加目标";
        nameField.text = "";
        // 以逻辑今天做日历加法，凌晨窗口不会比其它页面多算一天。
        var defaultDate = new Date(root.logicalToday());
        defaultDate.setDate(defaultDate.getDate() + 30);
        dateField.text = dateToInput(defaultDate);
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
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : 220
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
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.InQuad
            }
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: Theme.reduceMotion ? 0 : 180
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
                    color: cancelButton.pressed ? Theme.glassHover : (cancelButton.hovered ? Theme.glassHover : Theme.glassCard)
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
                    color: submitButton.pressed ? Theme.accentFillStrong : (submitButton.hovered ? Theme.accentFillStrong : Theme.accentFill)
                    border.color: submitButton.hovered || submitButton.pressed ? Theme.accentStrong : Theme.accent
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: submitButton.text
                    color: Theme.accentFillInk
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
