import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

// 仪表盘专注面板：重要控制组件，是仪表盘唯一做“背景采样毛玻璃”的地方。
// 液态玻璃四层：采样模糊(壁纸静态,代价可控) → 着色 → 受光棱边 → 内容；
// 无壁纸引用或关闭毛玻璃时降级为更实的半透明色块，文字对比度不受影响。
Item {
    id: root

    property var timerRef: null
    property var settingsRef: null
    property var wallpaperRef: null
    property int sessionCount: 0
    property int goalMinutes: 0
    // 降级开关：毛玻璃不可用（无壁纸引用/低配）时走纯色玻璃。
    property bool frostEnabled: true

    signal openFocusRequested()
    signal startRequested()
    // 仪表盘目标卡只读；未设置时用户点引导链接，向上请求跳到今日任务页。
    signal goalSetupRequested()
    // 用户点「隐藏」：面板自己不改布局，向上请求由 DashboardView 收起并持久化。
    signal hideRequested()

    readonly property bool frostActive: glassBackdrop.effectActive

    // —— 计时状态派生（字段显式经过 timerRef 属性读取，tick 信号才能驱动刷新）——
    readonly property int phase: root.timerRef ? Number(root.timerRef.phase) : 0
    readonly property bool hasSession: root.timerRef ? Boolean(root.timerRef.hasActiveSession) : false
    readonly property bool activeAny: root.phase !== 0 || root.hasSession
    readonly property bool running: root.timerRef ? Boolean(root.timerRef.isRunning) : false

    readonly property string statusText: root.activeAny
            ? (root.running ? (root.phase === 2 ? "休息中" : "专注中") : "已暂停")
            : "待机"

    readonly property string timeText: {
        if (root.phase !== 0) {
            return root.formatMinuteTime(root.timerRef.remainingSeconds)
        }
        if (root.hasSession) {
            return root.formatClockTime(root.timerRef.elapsedSeconds)
        }
        // 待机预览显示下一个番茄的时长，跟设置联动。
        var minutes = root.settingsRef ? Math.max(1, Number(root.settingsRef.workMinutes) || 25) : 25
        return root.formatMinuteTime(minutes * 60)
    }

    readonly property real ringProgress: {
        if (root.phase !== 0 && root.timerRef && Number(root.timerRef.targetSeconds) > 0) {
            return Number(root.timerRef.remainingSeconds) / Number(root.timerRef.targetSeconds)
        }
        return 1
    }

    // 今日已落库的专注秒数（由 DashboardView 注入统计口径）。
    property int todayFocusSeconds: 0

    // 实时口径统一走 FocusLiveSeconds，与今日任务页共用一份定义。
    readonly property int liveFocusSeconds: liveSecondsSource.liveSeconds

    readonly property FocusLiveSeconds liveSecondsSource: FocusLiveSeconds {
        timerRef: root.timerRef
        baseSeconds: root.todayFocusSeconds
    }

    // 采样区域 = 面板在壁纸坐标系里的矩形。mapToItem 本身不产生绑定依赖，
    // 这里显式引用面板与壁纸的几何属性，窗口缩放/布局变化时才会重算。
    readonly property rect frostRect: {
        if (!root.wallpaperRef) {
            return Qt.rect(0, 0, 1, 1)
        }
        var depend = root.x + root.y + root.width + root.height
                + root.wallpaperRef.width + root.wallpaperRef.height
        var pos = root.mapToItem(root.wallpaperRef, 0, 0)
        return Qt.rect(pos.x, pos.y, root.width, root.height)
    }

    function formatMinuteTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var minutes = Math.floor(safe / 60)
        var secs = safe % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (secs < 10 ? "0" : "") + secs
    }

    function formatClockTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function primaryAction() {
        if (!root.timerRef) {
            return
        }
        if (!root.activeAny) {
            root.startRequested()
            return
        }
        if (root.running) {
            root.timerRef.pauseFocus()
        } else {
            root.timerRef.resumeFocus()
        }
    }

    // Layer0：外层专注面板是本页唯一的实时背景采样区域。
    LiquidGlassBackdrop {
        id: glassBackdrop
        objectName: "dashboardTimerFrost"

        anchors.fill: parent
        sourceItem: root.wallpaperRef
        sourceRect: root.frostRect
        cornerRadius: Theme.radiusLg
        // 页面不可见时销毁 Shader/MultiEffect，避免 StackLayout 后台页面继续占 GPU pass。
        effectEnabled: root.frostEnabled && root.visible
        fallbackColor: Theme.glassSolidCard
    }

    // —— Layer 1+2：着色 + 受光棱边（毛玻璃在下时着色更透，降级时更实保对比度）——
    GlassPanel {
        anchors.fill: parent
        color: root.frostActive ? Theme.glassCard : Qt.rgba(1, 1, 1, 0)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space16
        spacing: Theme.space12

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Text {
                Layout.fillWidth: true
                text: "专注计时"
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
                color: Theme.inkStrong
            }

            Text {
                objectName: "dashboardTimerFocusLink"

                text: "专注页 ›"
                font.pixelSize: Theme.fontSm
                color: focusLinkArea.containsMouse ? Theme.accentInk : Theme.inkSoft

                MouseArea {
                    id: focusLinkArea

                    anchors.fill: parent
                    anchors.margins: -Theme.space4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openFocusRequested()
                }
            }

            Text {
                objectName: "dashboardTimerHideLink"

                text: "隐藏 »"
                font.pixelSize: Theme.fontSm
                color: hideLinkArea.containsMouse ? Theme.accentInk : Theme.inkSoft

                MouseArea {
                    id: hideLinkArea

                    anchors.fill: parent
                    anchors.margins: -Theme.space4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.hideRequested()
                }

                Accessible.role: Accessible.Button
                Accessible.name: "隐藏专注计时"
                Accessible.onPressAction: root.hideRequested()
            }
        }

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 180
            Layout.preferredHeight: 180

            FocusRing {
                anchors.fill: parent
                progress: root.ringProgress
                showPreview: !root.activeAny
                dimmed: root.activeAny && !root.running
                ringColor: root.phase === 2 ? Theme.focusBreakAccent : Theme.accent
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: Theme.space4

                Text {
                    objectName: "dashboardTimerTime"

                    Layout.alignment: Qt.AlignHCenter
                    text: root.timeText
                    textFormat: Text.PlainText
                    // 环内主数字介于 fontXxl 与 fontDisplay 之间，取 32 适配 180 环径。
                    font.pixelSize: 32
                    font.family: Theme.fontFamilyClock
                    font.weight: Font.Medium
                    color: Theme.inkStrong
                }

                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: statusLabel.implicitWidth + Theme.space16
                    implicitHeight: 22
                    radius: 11
                    color: Theme.glassAccent
                    border.color: Theme.glassBorder
                    border.width: 1

                    Text {
                        id: statusLabel
                        objectName: "dashboardTimerStatus"

                        anchors.centerIn: parent
                        text: root.statusText
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Medium
                        color: Theme.accentInk
                    }
                }
            }
        }

        Text {
            objectName: "dashboardTimerTaskTitle"

            Layout.fillWidth: true
            visible: root.activeAny && root.timerRef && String(root.timerRef.currentTaskTitle || "").length > 0
            text: root.timerRef ? String(root.timerRef.currentTaskTitle || "") : ""
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontMd
            color: Theme.ink
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            objectName: "dashboardTimerSessionCount"

            Layout.fillWidth: true
            text: "今日已专注 " + root.sessionCount + " 个番茄"
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
            horizontalAlignment: Text.AlignHCenter
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.space12

            Button {
                id: primaryButton
                objectName: "dashboardTimerPrimaryButton"

                text: root.activeAny ? (root.running ? "暂停" : "继续") : "开始专注"
                implicitWidth: 104
                implicitHeight: 34

                onClicked: root.primaryAction()

                // 与页面卡片同一玻璃基底：glassCard 半透明底 + 玻璃描边 + 受光棱边；
                // 悬停加实一档、按下用强调玻璃反馈，不再用大块实心焦糖。
                background: GlassPanel {
                    color: primaryButton.pressed ? Theme.glassAccent
                           : (primaryButton.hovered ? Theme.glassHover : Theme.glassCard)
                    panelShadowEnabled: false

                    Behavior on color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    text: primaryButton.text
                    textFormat: Text.PlainText
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: stopButton
                objectName: "dashboardTimerStopButton"

                visible: root.activeAny
                text: "结束"
                implicitWidth: 60
                implicitHeight: 34

                onClicked: {
                    if (root.timerRef) {
                        root.timerRef.stopFocus()
                    }
                }

                background: GlassPanel {
                    color: stopButton.hovered ? Theme.glassHover : Qt.rgba(1, 1, 1, 0)
                    specularEnabled: false
                    panelShadowEnabled: false

                    Behavior on color {
                        ColorAnimation {
                            duration: 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    text: stopButton.text
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        FocusGoalCard {
            id: goalCard
            objectName: "dashboardGoalCard"

            Layout.fillWidth: true
            Layout.topMargin: Theme.space4
            // 只读实例：展示与今日页同一份数据，设置动作引导回今日任务页。
            editable: false
            totalSeconds: root.liveFocusSeconds
            goalMinutes: root.goalMinutes
            reduceMotion: root.settingsRef ? Boolean(root.settingsRef.reduceMotion) : false

            onSetupRequested: root.goalSetupRequested()
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
