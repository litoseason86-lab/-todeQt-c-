import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 自由计时超时保险只负责呈现选择；保存、丢弃和后续页面动作由 FocusView 统一执行。
Popup {
    id: root

    objectName: "longFreeFocusConfirmDialog"

    property int elapsedSeconds: 0
    property int thresholdHours: 8
    property int suggestedDurationMinutes: 0
    property bool durationEdited: false
    property string errorText: ""

    signal recordRequested()
    signal adjustedRecordRequested(int durationSeconds)
    signal discardRequested()
    signal continueRequested()

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: Math.min(500, parent ? Math.max(320, parent.width - Theme.space32 * 2) : 500)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function elapsedLabel() {
        var safeSeconds = Math.max(0, Number(root.elapsedSeconds || 0))
        var hours = Math.floor(safeSeconds / 3600)
        var minutes = Math.floor((safeSeconds % 3600) / 60)
        return hours + " 小时" + (minutes > 0 ? " " + minutes + " 分钟" : "")
    }

    function prepare(elapsed, threshold) {
        root.elapsedSeconds = Math.max(0, Number(elapsed || 0))
        root.thresholdHours = Math.max(1, Number(threshold || 8))
        // 输入框按分钟修正；未改动时仍走 recordRequested，保留实际秒数。
        root.suggestedDurationMinutes = Math.max(3, Math.floor(root.elapsedSeconds / 60))
        root.durationEdited = false
        root.errorText = ""
        durationFields.reload()
    }

    function record() {
        if (!root.durationEdited) {
            root.recordRequested()
            root.close()
            return
        }
        if (durationFields.validationError.length > 0) {
            root.errorText = durationFields.validationError
            return
        }
        if (durationFields.enteredMinutes < 3) {
            root.errorText = "记录时长不能少于 3 分钟"
            return
        }
        // 修正只能往下调。预填的就是实际计时分钟数，改大意味着用户手滑（09:01 打成 90:01），
        // 而这条时长会直接进统计和长期目标进度，所以在这里就要拦住并说清上限。
        if (durationFields.enteredMinutes * 60 > root.elapsedSeconds) {
            root.errorText = "记录时长不能超过实际计时的 " + root.elapsedLabel()
            return
        }
        root.adjustedRecordRequested(durationFields.enteredMinutes * 60)
        root.close()
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
    }

    background: Rectangle {
        id: panel

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            color: Theme.surface
            radius: Theme.radiusMd

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: "确认自由计时记录"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "本次自由计时已持续 " + root.elapsedLabel()
                  + "，超过你设置的 " + root.thresholdHours
                  + " 小时提醒阈值。是否将这段时间写入专注记录？"
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Text {
                text: "修正记录时长"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            DurationFieldPair {
                id: durationFields
                objectName: "longFreeFocusDurationFields"
                namePrefix: "longFreeFocusDuration"
                totalMinutes: root.suggestedDurationMinutes
                maximumMinutes: 99 * 60 + 59
                compact: true
                accessiblePrefix: "修正记录时长"
                tabTarget: continueButton
                onUserEdited: {
                    root.durationEdited = true
                    root.errorText = ""
                }
                onAccepted: root.record()
            }

            Item { Layout.fillWidth: true }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "不修改则保留精确计时；修改后将按整分钟记录。"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        Text {
            objectName: "longFreeFocusAdjustmentError"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.errorText.length > 0
            text: root.errorText
            textFormat: Text.PlainText
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.AlertMessage
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "不记录会永久删除本次计时；继续计时则保持当前会话。"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            Layout.topMargin: Theme.space4
            spacing: Theme.space8

            Button {
                id: continueButton
                objectName: "longFreeFocusContinueButton"
                text: "继续计时"
                implicitWidth: 88
                implicitHeight: Theme.controlHeightMd
                activeFocusOnTab: true
                onClicked: {
                    root.continueRequested()
                    root.close()
                }

                background: Rectangle {
                    color: continueButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: continueButton.activeFocus ? Theme.focusRing : Theme.border
                    border.width: continueButton.activeFocus ? 2 : 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: continueButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: discardButton
                objectName: "longFreeFocusDiscardButton"
                text: "不记录"
                implicitWidth: 80
                implicitHeight: Theme.controlHeightMd
                activeFocusOnTab: true
                onClicked: {
                    root.discardRequested()
                    root.close()
                }

                background: Rectangle {
                    color: discardButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: discardButton.activeFocus ? Theme.focusRing : Theme.border
                    border.width: discardButton.activeFocus ? 2 : 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: discardButton.text
                    textFormat: Text.PlainText
                    color: Theme.dangerSoft
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: recordButton
                objectName: "longFreeFocusRecordButton"
                text: "记录计时"
                implicitWidth: 96
                implicitHeight: Theme.controlHeightMd
                activeFocusOnTab: true
                focus: true
                onClicked: root.record()

                background: Rectangle {
                    color: recordButton.hovered ? Theme.accentFillStrong : Theme.accentFill
                    border.color: recordButton.activeFocus ? Theme.focusRing : "transparent"
                    border.width: recordButton.activeFocus ? 2 : 0
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: recordButton.text
                    textFormat: Text.PlainText
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
