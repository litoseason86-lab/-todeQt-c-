pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    width: 208
    // 导航栏允许着色玻璃；实时模糊由 MainWindow.sidebarFrost 单层采样，这里不二次模糊。
    color: Theme.glassBlurAllowed ? Theme.glassSidebar : Theme.glassSolidSidebar
    // 玻璃侧栏上的条目默认态要“隐形”才能透出壁纸；但不能用 Qt 的 transparent（黑基透明）：
    // hover 退场的 ColorAnimation 会在黑白之间插出灰闪。白基透明只动 alpha，不经过灰。
    readonly property color sidebarItemIdleColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemIdleBorderColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemHoverColor: Qt.rgba(1, 1, 1, 0.45)
    readonly property color sidebarItemHoverBorderColor: Theme.border
    readonly property color sidebarItemActiveColor: Theme.glassAccent
    readonly property color sidebarItemActiveBorderColor: Theme.accent

    property string currentView: "today"
    property var focusTimerRef: null
    // 减少动效默认读全局 appSettings；测试可直接覆盖该属性，避免为了一个开关伪造整套上下文。
    // qmllint disable unqualified
    property bool reduceMotionActive: typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
    // qmllint enable unqualified
    signal itemClicked(string viewName)
    signal settingsRequested
    // 请求收起侧栏：由 MainWindow 做宽度动画与持久化，侧栏自身不持有布局态。
    signal collapseRequested()

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

    function focusStatusFor(hasActiveSession, phase, mode, isRunning, remainingSeconds, elapsedSeconds) {
        // 参数显式传入，保证 QML 绑定依赖具体 timer 属性；tick 才能驱动文本每秒刷新。
        var active = hasActiveSession || phase !== 0
        if (!active) {
            return ""
        }
        var timeText = mode === 1 ? root.formatMinuteTime(remainingSeconds) : root.formatClockTime(elapsedSeconds)
        return (isRunning ? "● " : "⏸ ") + timeText
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space16
        spacing: Theme.space4

        // 标题行右侧放 Apple 风侧栏切换钮（收起）。
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.space8
            spacing: Theme.space8

            Text {
                text: "番茄Todo"
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
                color: Theme.ink
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            GlassToolbarButton {
                id: collapseButton
                objectName: "sidebarCollapseButton"

                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                implicitWidth: 30
                implicitHeight: 30
                reduceMotion: root.reduceMotionActive
                // 嵌在侧栏玻璃上：关掉落影，避免双层阴影发灰。
                solidFallback: !Theme.glassBlurAllowed
                Accessible.name: "隐藏侧栏"
                onClicked: root.collapseRequested()

                // 侧栏内嵌钮不需要再套一层 panel 阴影。
                Component.onCompleted: {
                    if (background && background.panelShadowEnabled !== undefined)
                        background.panelShadowEnabled = false
                }
            }
        }

        Text {
            text: "时间视图"
            font.pixelSize: Theme.fontSm
            font.weight: Font.Bold
            color: Theme.inkSoft
            Layout.bottomMargin: Theme.space8
        }

        SidebarItem {
            text: "仪表盘"
            marker: "仪"
            isActive: root.currentView === "dashboard"
            onClicked: root.itemClicked("dashboard")
        }

        SidebarItem {
            text: "今日任务"
            marker: "今"
            isActive: root.currentView === "today"
            onClicked: root.itemClicked("today")
        }

        SidebarItem {
            text: "专注计时"
            marker: "专"
            isActive: root.currentView === "focus"
            statusText: root.focusTimerRef
                        ? root.focusStatusFor(root.focusTimerRef.hasActiveSession,
                                              root.focusTimerRef.phase,
                                              root.focusTimerRef.mode,
                                              root.focusTimerRef.isRunning,
                                              root.focusTimerRef.remainingSeconds,
                                              root.focusTimerRef.elapsedSeconds)
                        : ""
            onClicked: root.itemClicked("focus")
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
            Layout.topMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            opacity: 0.8
        }

        SidebarItem {
            text: "本周计划"
            marker: "周"
            isActive: root.currentView === "week"
            onClicked: root.itemClicked("week")
        }

        SidebarItem {
            text: "专注历史"
            marker: "月"
            isActive: root.currentView === "month"
            onClicked: root.itemClicked("month")
        }

        SidebarItem {
            text: "数据统计"
            marker: "数"
            isActive: root.currentView === "stats"
            onClicked: root.itemClicked("stats")
        }

        SidebarItem {
            text: "目标倒计时"
            marker: "倒"
            isActive: root.currentView === "countdown"
            onClicked: root.itemClicked("countdown")
        }

        Item {
            Layout.fillHeight: true
        }

        SidebarItem {
            text: "设置"
            marker: "设"
            isActive: false
            onClicked: root.settingsRequested()
        }
    }

    component SidebarItem: Rectangle {
        id: item

        property string text: ""
        property string marker: ""
        property bool isActive: false
        property string statusText: ""
        readonly property string statusGlyph: item.statusText.indexOf("● ") === 0
                                             ? "●"
                                             : (item.statusText.indexOf("⏸ ") === 0 ? "⏸" : "")
        readonly property string statusTimeText: item.statusGlyph.length > 0
                                                ? item.statusText.slice(2)
                                                : item.statusText
        // 显式状态能抵消 MouseArea 和 HoverHandler 在不同设备上的悬停事件差异。
        property bool pointerInside: false
        readonly property bool visualHovered: item.enabled && item.pointerInside
        signal clicked

        function setPointerInside(inside) {
            item.pointerInside = item.enabled && inside;
        }

        objectName: "sidebarItem-" + item.marker
        Layout.fillWidth: true
        Layout.preferredHeight: 44
        radius: Theme.radiusMd
        // 不能把非激活状态设为 transparent：Qt 的 transparent 是黑基透明，
        // hover 退场时 ColorAnimation 会插出灰色。白基透明只变化 alpha，能透出壁纸且不灰闪。
        color: item.isActive ? root.sidebarItemActiveColor : (item.visualHovered ? root.sidebarItemHoverColor : root.sidebarItemIdleColor)
        border.color: item.isActive ? root.sidebarItemActiveBorderColor : (item.visualHovered ? root.sidebarItemHoverBorderColor : root.sidebarItemIdleBorderColor)
        border.width: item.isActive || item.visualHovered ? 1 : 0
        opacity: item.enabled ? 1.0 : 0.55
        // 侧边栏只用颜色和边框反馈，避免悬浮或选中时先出现阴影造成顿挫。
        layer.enabled: false

        Behavior on color {
            ColorAnimation {
                duration: 70
                easing.type: Easing.OutQuad
            }
        }

        Behavior on border.color {
            ColorAnimation {
                duration: 70
                easing.type: Easing.OutQuad
            }
        }

        Behavior on border.width {
            NumberAnimation {
                duration: 70
                easing.type: Easing.OutQuad
            }
        }

        onEnabledChanged: {
            if (!item.enabled) {
                item.pointerInside = false;
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.space8
            anchors.rightMargin: Theme.space8
            spacing: Theme.space8

            Rectangle {
                objectName: "sidebarMarker-" + item.marker
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: Theme.radiusSm
                color: item.isActive ? Theme.accentFill : Theme.glassCard

                Behavior on color {
                    ColorAnimation {
                        duration: 70
                        easing.type: Easing.OutQuad
                    }
                }

                Text {
                    anchors.centerIn: parent
                    text: item.marker
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Bold
                    color: item.isActive ? Theme.accentFillInk : Theme.inkSoft

                    Behavior on color {
                        ColorAnimation {
                            duration: 70
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: item.text
                font.pixelSize: Theme.fontLg
                font.weight: item.isActive ? Font.Medium : Font.Normal
                color: item.isActive ? Theme.ink : Theme.inkSoft
                elide: Text.ElideRight
            }

            RowLayout {
                spacing: Theme.space4

                Text {
                    id: statusPulse
                    objectName: "sidebarStatusPulse-" + item.marker

                    property bool pulseRunning: item.statusGlyph === "●"
                    readonly property bool pulseAnimationRunning: pulseAnimation.running

                    text: item.statusGlyph
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    color: Theme.accentInk

                    SequentialAnimation on opacity {
                        id: pulseAnimation

                        running: statusPulse.pulseRunning && !root.reduceMotionActive
                        loops: Animation.Infinite

                        NumberAnimation {
                            from: 1.0
                            to: 0.35
                            duration: 620
                            easing.type: Easing.InOutQuad
                        }

                        NumberAnimation {
                            from: 0.35
                            to: 1.0
                            duration: 620
                            easing.type: Easing.InOutQuad
                        }

                        onRunningChanged: {
                            // 减少动效或状态变化都会停动画；停在半透明帧会像“禁用态”，所以回到不透明。
                            if (!running) {
                                statusPulse.opacity = 1
                            }
                        }
                    }

                    onPulseRunningChanged: {
                        if (!statusPulse.pulseRunning) {
                            statusPulse.opacity = 1
                        }
                    }
                }

                Text {
                    objectName: "sidebarStatus-" + item.marker
                    text: item.statusTimeText
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamilyClock
                    font.weight: Font.Medium
                    color: Theme.accentInk
                }
            }
        }

        MouseArea {
            id: mouseArea

            objectName: "sidebarHitArea-" + item.marker
            anchors.fill: parent
            hoverEnabled: true
            enabled: item.enabled
            cursorShape: Qt.PointingHandCursor
            onEntered: item.setPointerInside(true)
            onExited: item.setPointerInside(false)
            onClicked: item.clicked()
        }

        HoverHandler {
            id: hoverHandler
            enabled: item.enabled
            // 某些 Qt/macOS 触控板路径可能绕过 MouseArea 的进入/离开事件。
            onHoveredChanged: item.setPointerInside(hovered)
        }
    }
}
