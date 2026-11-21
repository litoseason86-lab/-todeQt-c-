import QtQuick
import QtQuick.Controls.Basic
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
    // 备份或恢复处于数据库临界区时由 MainWindow 置真，阻断 Esc 快捷键穿透。
    property bool inputBlocked: false

    signal exitRequested()

    readonly property string projectedState: focusViewRef ? String(focusViewRef.state) : ""
    readonly property bool completionState: projectedState === "workDone" || projectedState === "breakDone"

    readonly property bool sessionPaused: {
        if (!timerRef || Boolean(timerRef.isRunning)) {
            return false
        }
        if (projectedState === "manualRest" || projectedState === "pomoWork" || projectedState === "pomoBreak") {
            return true
        }
        return projectedState === "free" && Boolean(timerRef.hasActiveSession)
    }

    // 待机或无会话自由态没有可投影内容；后续退出联动据此避免出现空白全屏。
    readonly property bool projectable: {
        if (!focusViewRef || !timerRef) {
            return false
        }
        if (projectedState === "manualRest" || projectedState === "pomoWork"
                || projectedState === "pomoBreak" || completionState) {
            return true
        }
        return projectedState === "free" && Boolean(timerRef.hasActiveSession)
    }

    // 鼠标移动后控制浮现 3 秒；暂停和完成态固定显示，避免关键动作自己消失。
    property bool controlsRevealed: false
    readonly property bool controlsPinned: sessionPaused || completionState
    readonly property bool controlsShown: controlsRevealed || controlsPinned
    readonly property bool fadeAnimated: !Theme.reduceMotion
                                         && !(settingsRef && settingsRef.reduceMotion)
    readonly property alias hideTimerRunning: hideTimer.running

    function revealControls() {
        controlsRevealed = true
        hideTimer.restart()
    }

    function hideControls() {
        controlsRevealed = false
    }

    function requestExit() {
        root.exitRequested()
    }

    // 沉浸中若意外落入待机或无会话自由态，立即退出，不能留下空白全屏。
    onProjectableChanged: {
        if (active && !projectable) {
            requestExit()
        }
    }

    onActiveChanged: {
        if (active && !projectable) {
            requestExit()
        }
    }

    readonly property string primaryButtonText: {
        if (projectedState === "workDone") {
            return "开始休息"
        }
        if (projectedState === "breakDone") {
            return "开始专注"
        }
        return timerRef && timerRef.isRunning ? "暂停" : "继续"
    }

    // 完成态按钮镜像 FocusView 的业务前置条件，防止任务上下文缺失时误亮。
    readonly property bool primaryButtonEnabled: {
        if (projectedState === "workDone") {
            return true
        }
        if (projectedState === "breakDone") {
            return focusViewRef ? Boolean(focusViewRef.canStartPomodoro()) : false
        }
        if (projectedState === "free") {
            return timerRef ? Boolean(timerRef.hasActiveSession) : false
        }
        return timerRef ? Number(timerRef.phase || 0) !== 0 : false
    }

    readonly property string secondaryButtonText: {
        if (projectedState === "manualRest") {
            return "结束休息"
        }
        if (projectedState === "pomoBreak") {
            return "跳过休息"
        }
        if (projectedState === "free") {
            return "结束专注"
        }
        return "结束"
    }

    function triggerPrimary() {
        if (!focusViewRef) {
            return
        }
        if (projectedState === "workDone") {
            focusViewRef.startBreak()
            return
        }
        if (projectedState === "breakDone") {
            focusViewRef.startPomodoro()
            return
        }
        focusViewRef.togglePause()
    }

    function triggerSecondary() {
        if (!focusViewRef) {
            return
        }
        if (projectedState === "free") {
            focusViewRef.endFreeFocus()
            return
        }
        if (projectedState === "manualRest") {
            focusViewRef.endManualRest()
            return
        }
        focusViewRef.endPomodoro()
    }

    function viewText(name) {
        return focusViewRef ? String(focusViewRef[name]()) : ""
    }

    Timer {
        id: hideTimer

        interval: 3000
        onTriggered: root.hideControls()
    }

    function itemInsideOverlay(item) {
        const overlayLayer = root.Overlay.overlay
        if (!overlayLayer || !item) {
            return false
        }
        let current = item
        while (current) {
            if (current === overlayLayer) {
                return true
            }
            current = current.parent
        }
        return false
    }

    readonly property bool overlayHoldsFocus: root.itemInsideOverlay(
        root.Window.window ? root.Window.window.activeFocusItem : null)

    Shortcut {
        sequence: "Esc"
        // 顶层浮层弹窗（如快速记一笔、确认框）持焦，或备份/恢复阻断输入时，不穿透退出沉浸态。
        enabled: root.active && !root.overlayHoldsFocus && !root.inputBlocked
        onActivated: root.requestExit()
    }

    // 沉浸态直接铺主题壁纸原图（不带可读性罩层），氛围完整展示。
    BackgroundWallpaper {
        objectName: "immersiveBackdrop"

        anchors.fill: parent
        themeId: root.settingsRef && root.settingsRef.backgroundTheme
                 ? root.settingsRef.backgroundTheme
                 : "warm"

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
                color: Theme.glassAccent
                border.color: Theme.accent
                radius: Theme.radiusMd

                Text {
                    id: bannerText
                    objectName: "immersiveBannerText"

                    anchors.centerIn: parent
                    text: root.viewText("pomodoroStageText")
                    textFormat: Text.PlainText
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
                        textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                objectName: "immersiveErrorText"

                Layout.fillWidth: true
                text: root.focusViewRef ? String(root.focusViewRef.errorText) : ""
                textFormat: Text.PlainText
                visible: text.length > 0
                font.pixelSize: Theme.fontMd
                color: Theme.danger
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }

        RowLayout {
            id: topControls

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Theme.space16
            spacing: Theme.space8
            opacity: root.controlsShown ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
                enabled: root.fadeAnimated
                NumberAnimation { duration: Theme.reduceMotion ? 0 : 180 }
            }

            Button {
                id: immersiveExitButton
                objectName: "immersiveExitButton"
                Accessible.name: qsTr("退出沉浸模式")

                implicitWidth: 40
                implicitHeight: Theme.controlHeightMd

                onClicked: root.requestExit()

                background: Rectangle {
                    color: immersiveExitButton.hovered ? Theme.surface : "transparent"
                    border.color: immersiveExitButton.visualFocus
                                  ? Theme.focusRing
                                  : (immersiveExitButton.hovered ? Theme.border : "transparent")
                    border.width: immersiveExitButton.visualFocus ? 2 : 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: "✕"
                    font.pixelSize: Theme.fontLg
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        RowLayout {
            id: bottomControls

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.space32
            spacing: Theme.space16
            opacity: root.controlsShown ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
                enabled: root.fadeAnimated
                NumberAnimation { duration: Theme.reduceMotion ? 0 : 180 }
            }

            Button {
                id: immersivePrimaryButton
                objectName: "immersivePrimaryButton"

                // 与页面内「开始专注」同尺寸；暂停/继续/开始休息也走同一玻璃主按钮。
                implicitWidth: 104
                implicitHeight: Theme.controlHeightMd
                enabled: root.primaryButtonEnabled

                onClicked: root.triggerPrimary()

                background: GlassPanel {
                    color: {
                        if (!immersivePrimaryButton.enabled)
                            return Theme.border
                        if (immersivePrimaryButton.pressed || immersivePrimaryButton.down)
                            return Theme.glassAccent
                        if (immersivePrimaryButton.hovered)
                            return Theme.glassHover
                        return Theme.glassCard
                    }
                    border.color: immersivePrimaryButton.visualFocus ? Theme.focusRing : Theme.glassBorder
                    border.width: immersivePrimaryButton.visualFocus ? 2 : 1
                    panelShadowEnabled: false

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    text: root.primaryButtonText
                    textFormat: Text.PlainText
                    // 从禁用底色过渡到玻璃底色时也要可读，不能只满足动画结束后的对比度。
                    color: immersivePrimaryButton.enabled ? Theme.inkStrong : Theme.inkMuted
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: immersiveSecondaryButton
                objectName: "immersiveSecondaryButton"

                implicitWidth: 104
                implicitHeight: Theme.controlHeightMd

                onClicked: root.triggerSecondary()

                // 次按钮：同色零透明玻璃底，悬停才加实；用 glassHoverIdle 避免暗色主题白雾插值闪烁。
                background: GlassPanel {
                    color: immersiveSecondaryButton.hovered ? Theme.glassHover : Theme.glassHoverIdle
                    border.color: immersiveSecondaryButton.visualFocus ? Theme.focusRing : Theme.glassBorder
                    border.width: immersiveSecondaryButton.visualFocus ? 2 : 1
                    specularEnabled: false
                    panelShadowEnabled: false

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    text: root.secondaryButtonText
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
