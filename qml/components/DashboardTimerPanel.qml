import QtQuick
import QtQuick.Controls
import QtQuick.Effects
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
    // 降级开关：毛玻璃不可用（无壁纸引用/低配）时走纯色玻璃。
    property bool frostEnabled: true

    signal openFocusRequested()
    signal startRequested()

    readonly property bool frostActive: root.frostEnabled && root.wallpaperRef !== null

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

    // 实时总时长 = 落库累计 + 进行中会话秒数；休息阶段不累计，与统计口径一致。
    // 显式经由 timerRef.elapsedSeconds 读取，tick 信号才能驱动逐秒走字。
    readonly property int liveFocusSeconds: {
        var base = Math.max(0, Number(root.todayFocusSeconds || 0))
        if (root.timerRef && (root.phase === 1 || (root.phase === 0 && root.hasSession))) {
            base += Math.max(0, Number(root.timerRef.elapsedSeconds || 0))
        }
        return base
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

    // —— 液态玻璃 Layer 0：壁纸采样 + 模糊，圆角遮罩防止四角溢出 ——
    // 壁纸是静态图，纹理只在图片加载/换主题时重传，模糊代价限定在本面板区域。
    ShaderEffectSource {
        id: frostSource

        visible: false
        sourceItem: root.wallpaperRef
        sourceRect: root.frostRect
    }

    Rectangle {
        id: frostMask

        anchors.fill: parent
        radius: Theme.radiusLg
        visible: false
    }

    MultiEffect {
        objectName: "dashboardTimerFrost"

        anchors.fill: parent
        visible: root.frostActive
        source: frostSource
        blurEnabled: true
        blur: 0.9
        blurMax: 48
        maskEnabled: true
        maskSource: frostMask
    }

    // —— Layer 1+2：着色 + 受光棱边（毛玻璃在下时着色更透，降级时更实保对比度）——
    GlassPanel {
        anchors.fill: parent
        color: root.frostActive ? Theme.glassCard : Theme.glassHover
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
            objectName: "dashboardGoalCard"

            Layout.fillWidth: true
            Layout.topMargin: Theme.space4
            totalSeconds: root.liveFocusSeconds
            goalHours: root.settingsRef
                       ? Math.max(1, Number(root.settingsRef.dailyFocusGoalHours) || 3)
                       : 3

            onGoalAdjusted: function (hours) {
                if (root.settingsRef) {
                    root.settingsRef.dailyFocusGoalHours = hours
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
