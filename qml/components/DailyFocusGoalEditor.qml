import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

FocusScope {
    id: root

    property int initialMinutes: 0
    property bool reduceMotion: false
    property string validationError: ""

    readonly property alias hourText: hourField.text
    readonly property alias minuteText: minuteField.text

    signal submitted(int totalMinutes)
    signal cancelled()

    implicitHeight: editorColumn.implicitHeight
    opacity: 0
    scale: 0.98

    Component.onCompleted: {
        root.loadInitialValue()
        root.opacity = 1
        root.scale = 1
        hourField.forceActiveFocus()
        hourField.selectAll()
    }

    Behavior on opacity {
        enabled: !root.reduceMotion
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }

    Behavior on scale {
        enabled: !root.reduceMotion
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }

    function loadInitialValue() {
        var safe = Math.max(0, Math.min(1440, Number(root.initialMinutes || 0)))
        hourField.text = String(Math.floor(safe / 60))
        minuteField.text = String(safe % 60)
        root.validationError = ""
    }

    function submit() {
        if (!hourField.acceptableInput || !minuteField.acceptableInput
                || hourField.text.length === 0 || minuteField.text.length === 0) {
            root.validationError = qsTr("请输入有效的小时和分钟")
            return
        }

        var hours = Number(hourField.text)
        var minutes = Number(minuteField.text)
        var totalMinutes = hours * 60 + minutes
        if (totalMinutes <= 0) {
            root.validationError = qsTr("目标至少需要 1 分钟")
            return
        }
        if (hours === 24 && minutes !== 0) {
            root.validationError = qsTr("24 小时是上限，分钟必须为 0")
            return
        }
        if (totalMinutes > 1440) {
            root.validationError = qsTr("目标不能超过 24 小时")
            return
        }

        root.validationError = ""
        root.submitted(totalMinutes)
    }

    Keys.onEscapePressed: function(event) {
        root.cancelled()
        event.accepted = true
    }

    ColumnLayout {
        id: editorColumn

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Theme.space8

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            TextField {
                id: hourField
                objectName: "focusGoalHourField"

                Layout.fillWidth: true
                Layout.preferredHeight: 38
                activeFocusOnTab: true
                selectByMouse: true
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhDigitsOnly
                maximumLength: 2
                font.pixelSize: Theme.fontMd
                color: Theme.inkStrong
                Accessible.name: qsTr("今日专注目标小时")
                validator: IntValidator { bottom: 0; top: 24 }
                KeyNavigation.tab: minuteField
                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: hourField.activeFocus ? 2 : 1
                    border.color: hourField.activeFocus ? Theme.accent : Theme.borderSubtle
                }
            }

            Label {
                text: qsTr("小时")
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }

            TextField {
                id: minuteField
                objectName: "focusGoalMinuteField"

                Layout.fillWidth: true
                Layout.preferredHeight: 38
                activeFocusOnTab: true
                selectByMouse: true
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhDigitsOnly
                maximumLength: 2
                font.pixelSize: Theme.fontMd
                color: Theme.inkStrong
                Accessible.name: qsTr("今日专注目标分钟")
                validator: IntValidator { bottom: 0; top: 59 }
                KeyNavigation.tab: cancelButton
                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: minuteField.activeFocus ? 2 : 1
                    border.color: minuteField.activeFocus ? Theme.accent : Theme.borderSubtle
                }
            }

            Label {
                text: qsTr("分钟")
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
        }

        Label {
            objectName: "focusGoalValidationError"

            Layout.fillWidth: true
            visible: root.validationError.length > 0
            text: root.validationError
            color: Theme.danger
            font.pixelSize: Theme.fontXs
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.AlertMessage
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Item { Layout.fillWidth: true }

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
                KeyNavigation.tab: hourField
                onClicked: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: saveButton.pressed ? Theme.accentStrong : Theme.accent
                    border.width: saveButton.visualFocus ? 2 : 1
                    border.color: saveButton.visualFocus ? Theme.inkStrong : Theme.glassBorder
                }

                contentItem: Text {
                    text: saveButton.text
                    color: Theme.surface
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
