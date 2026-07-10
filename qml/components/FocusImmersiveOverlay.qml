import QtQuick
import QtQuick.Layouts
import ".."

// 全屏沉浸层只投影 FocusView 的运行状态并转发动作，不持有第二套计时业务状态。
// 时间、文案与环参数全部复用 FocusView 现有接口，避免普通页和沉浸页口径分叉。
Item {
    id: root

    property var focusViewRef: null
    property var timerRef: null
    property var settingsRef: null
    property bool active: false

    readonly property string projectedState: focusViewRef ? String(focusViewRef.state) : ""
    readonly property bool completionState: projectedState === "workDone" || projectedState === "breakDone"

    readonly property bool sessionPaused: {
        if (!timerRef || Boolean(timerRef.isRunning)) {
            return false
        }
        if (projectedState === "pomoWork" || projectedState === "pomoBreak") {
            return true
        }
        return projectedState === "free" && Boolean(timerRef.hasActiveSession)
    }

    // 待机或无会话自由态没有可投影内容；后续退出联动据此避免出现空白全屏。
    readonly property bool projectable: {
        if (!focusViewRef || !timerRef) {
            return false
        }
        if (projectedState === "pomoWork" || projectedState === "pomoBreak" || completionState) {
            return true
        }
        return projectedState === "free" && Boolean(timerRef.hasActiveSession)
    }

    // 鼠标移动后控制浮现 3 秒；暂停和完成态固定显示，避免关键动作自己消失。
    property bool controlsRevealed: false
    readonly property bool controlsPinned: sessionPaused || completionState
    readonly property bool controlsShown: controlsRevealed || controlsPinned
    readonly property bool fadeAnimated: !(settingsRef && settingsRef.reduceMotion)
    readonly property alias hideTimerRunning: hideTimer.running

    function revealControls() {
        controlsRevealed = true
        hideTimer.restart()
    }

    function hideControls() {
        controlsRevealed = false
    }

    function viewText(name) {
        return focusViewRef ? String(focusViewRef[name]()) : ""
    }

    Timer {
        id: hideTimer

        interval: 3000
        onTriggered: root.hideControls()
    }

    Rectangle {
        objectName: "immersiveBackdrop"

        anchors.fill: parent
        color: Theme.glassCard

        MouseArea {
            objectName: "immersiveHoverArea"

            anchors.fill: parent
            hoverEnabled: true
            // 只观察移动，不接收点击；后续浮现的控制按钮必须能正常命中。
            acceptedButtons: Qt.NoButton
            cursorShape: root.controlsShown ? Qt.ArrowCursor : Qt.BlankCursor

            onPositionChanged: root.revealControls()
        }

        ColumnLayout {
            width: Math.min(parent.width - 96, 640)
            spacing: Theme.space16

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredHeight: 44
                Layout.preferredWidth: bannerText.implicitWidth + Theme.space24 * 2
                visible: root.completionState
                color: Theme.accentSoft
                border.color: Theme.accent
                radius: Theme.radiusMd

                Text {
                    id: bannerText
                    objectName: "immersiveBannerText"

                    anchors.centerIn: parent
                    text: root.viewText("pomodoroStageText")
                    font.pixelSize: Theme.fontLg
                    font.bold: true
                    color: Theme.inkStrong
                }
            }

            FocusRing {
                objectName: "immersiveRing"

                Layout.alignment: Qt.AlignHCenter
                visible: root.projectedState !== "free"
                implicitWidth: 340
                implicitHeight: implicitWidth
                showPreview: false
                dimmed: root.focusViewRef ? Boolean(root.focusViewRef.ringDimmed()) : false
                progress: root.focusViewRef ? Number(root.focusViewRef.ringProgressFraction()) : 1
                ringColor: root.focusViewRef ? root.focusViewRef.ringColorForState() : Theme.accent

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Theme.space4

                    Text {
                        objectName: "immersiveRingTimeText"

                        Layout.alignment: Qt.AlignHCenter
                        text: root.focusViewRef
                              ? String(root.focusViewRef.ringTimeMarkup(root.focusViewRef.primaryTimeText()))
                              : ""
                        textFormat: Text.StyledText
                        font.pixelSize: Theme.fontDisplay
                        font.family: Theme.fontFamilyClock
                        font.weight: (root.settingsRef && root.settingsRef.slimClockFont) ? Font.Light : Font.Medium
                        color: root.focusViewRef ? root.focusViewRef.primaryTimeColor() : Theme.accentInk
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.viewText("ringCaptionText")
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkSoft
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Text {
                objectName: "immersiveFreeTimeText"

                Layout.fillWidth: true
                visible: root.projectedState === "free"
                text: root.viewText("primaryTimeText")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontDisplay + Theme.fontXxl
                font.family: Theme.fontFamilyClock
                font.weight: (root.settingsRef && root.settingsRef.slimClockFont) ? Font.Light : Font.Medium
                color: root.focusViewRef ? root.focusViewRef.primaryTimeColor() : Theme.accentInk
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                objectName: "immersiveTaskText"

                Layout.fillWidth: true
                text: root.viewText("taskTitle")
                font.pixelSize: Theme.fontXl
                font.bold: true
                color: Theme.ink
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Text {
                objectName: "immersiveStageText"

                Layout.fillWidth: true
                visible: !root.completionState
                text: root.projectedState === "free"
                      ? root.viewText("runningText")
                      : root.viewText("pomodoroStageText")
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                objectName: "immersiveErrorText"

                Layout.fillWidth: true
                text: root.focusViewRef ? String(root.focusViewRef.errorText) : ""
                visible: text.length > 0
                font.pixelSize: Theme.fontMd
                color: Theme.danger
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
