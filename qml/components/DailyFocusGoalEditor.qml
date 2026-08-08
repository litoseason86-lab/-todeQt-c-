import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

FocusScope {
    id: root

    property int initialMinutes: 0
    property bool reduceMotion: false
    property string validationError: ""
    // 横排模式：底部目标条内联编辑用；竖排（默认）留给卡片形态。
    property bool horizontal: false


    signal submitted(int totalMinutes)
    signal cancelled()

    implicitHeight: editorColumn.implicitHeight
    opacity: 0
    scale: 0.98

    Component.onCompleted: {
        root.loadInitialValue()
        root.opacity = 1
        root.scale = 1
        durationFields.focusFirstField()
    }

    Behavior on opacity {
        enabled: !root.reduceMotion
        NumberAnimation { duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.OutCubic }
    }

    Behavior on scale {
        enabled: !root.reduceMotion
        NumberAnimation { duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.OutCubic }
    }

    function loadInitialValue() {
        durationFields.totalMinutes = Math.max(0, Math.min(1440, Number(root.initialMinutes || 0)))
        durationFields.reload()
        root.validationError = ""
    }

    function submit() {
        // 形式校验（能否解析、是否越界）在共享字段里，这里只补目标特有的下限。
        if (durationFields.validationError.length > 0) {
            root.validationError = durationFields.validationError
            return
        }
        if (durationFields.enteredMinutes <= 0) {
            root.validationError = qsTr("目标至少需要 1 分钟")
            return
        }

        root.validationError = ""
        root.submitted(durationFields.enteredMinutes)
    }

    Keys.onEscapePressed: function(event) {
        root.cancelled()
        event.accepted = true
    }

    GridLayout {
        id: editorColumn

        anchors.left: parent.left
        anchors.right: parent.right
        // 竖排=三行（输入/报错/按钮），横排=一行三组并列。
        flow: root.horizontal ? GridLayout.LeftToRight : GridLayout.TopToBottom
        columns: root.horizontal ? 3 : 1
        rows: root.horizontal ? 1 : 3
        rowSpacing: Theme.space8
        columnSpacing: Theme.space12

        DurationFieldPair {
            id: durationFields

            Layout.fillWidth: !root.horizontal
            compact: root.horizontal
            namePrefix: "focusGoal"
            accessiblePrefix: qsTr("今日专注目标")
            tabTarget: cancelButton
            onAccepted: root.submit()
        }

        Label {
            objectName: "focusGoalValidationError"

            Layout.fillWidth: true
            visible: root.horizontal || root.validationError.length > 0
            text: root.validationError
            color: Theme.danger
            font.pixelSize: Theme.fontXs
            wrapMode: root.horizontal ? Text.NoWrap : Text.WordWrap
            elide: root.horizontal ? Text.ElideRight : Text.ElideNone
            Accessible.role: Accessible.AlertMessage
        }

        RowLayout {
            Layout.fillWidth: !root.horizontal
            spacing: Theme.space8

            Item { Layout.fillWidth: !root.horizontal }

            Button {
                id: cancelButton
                objectName: "focusGoalCancelButton"

                text: qsTr("取消")
                activeFocusOnTab: true
                implicitWidth: 64
                implicitHeight: 32
                KeyNavigation.tab: saveButton
                onClicked: root.cancelled()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: cancelButton.hovered ? Theme.glassHover : Qt.rgba(1, 1, 1, 0)
                    border.width: cancelButton.visualFocus ? 2 : 1
                    border.color: cancelButton.visualFocus ? Theme.accent : Theme.borderSubtle
                }
            }

            Button {
                id: saveButton
                objectName: "focusGoalSaveButton"

                text: qsTr("保存")
                activeFocusOnTab: true
                implicitWidth: 64
                implicitHeight: 32
                KeyNavigation.tab: durationFields.firstField
                onClicked: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: saveButton.pressed ? Theme.accentFillStrong : Theme.accentFill
                    border.width: saveButton.visualFocus ? 2 : 1
                    border.color: saveButton.visualFocus ? Theme.inkStrong : Theme.glassBorder
                }

                contentItem: Text {
                    text: saveButton.text
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
