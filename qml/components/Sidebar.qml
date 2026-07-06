pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    width: 208
    color: Theme.glassSidebar
    // 玻璃侧栏上的条目默认态要“隐形”才能透出壁纸；但不能用 Qt 的 transparent（黑基透明）：
    // hover 退场的 ColorAnimation 会在黑白之间插出灰闪。白基透明只动 alpha，不经过灰。
    readonly property color sidebarItemIdleColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemIdleBorderColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemHoverColor: Qt.rgba(1, 1, 1, 0.45)
    readonly property color sidebarItemHoverBorderColor: Theme.border
    readonly property color sidebarItemActiveColor: Theme.accentSoft
    readonly property color sidebarItemActiveBorderColor: Theme.accent

    property string currentView: "today"
    property var categoryManagerRef: null
    property var exportServiceRef: null
    property var focusTimerRef: null
    signal itemClicked(string viewName)
    signal dailyRoutineRequested
    signal categoryManagementRequested
    signal dataExportRequested
    signal settingsRequested

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

        Text {
            text: "番茄Todo"
            font.pixelSize: Theme.fontXl
            font.weight: Font.Bold
            color: Theme.ink
            Layout.bottomMargin: Theme.space16
        }

        Text {
            text: "时间视图"
            font.pixelSize: Theme.fontSm
            font.weight: Font.Bold
            color: Theme.inkSoft
            Layout.bottomMargin: Theme.space8
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
            text: "每日例行"
            marker: "例"
            isActive: false
            onClicked: root.dailyRoutineRequested()
        }

        SidebarItem {
            text: "科目管理"
            marker: "科"
            isActive: false
            onClicked: root.categoryManagementRequested()
        }

        SidebarItem {
            text: "数据导出"
            marker: "导"
            isActive: false
            onClicked: root.dataExportRequested()
        }

        SidebarItem {
            text: "设置"
            marker: "设"
            isActive: false
            onClicked: root.settingsRequested()
        }

        Text {
            text: "三阶段"
            font.pixelSize: Theme.fontSm
            font.weight: Font.Normal
            color: Theme.inkMuted
            opacity: 0.7
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
                color: item.isActive ? Theme.accent : Theme.border

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
                    color: item.isActive ? Theme.surface : Theme.inkSoft

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

                    text: item.statusGlyph
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    color: Theme.accent

                    SequentialAnimation on opacity {
                        id: pulseAnimation

                        running: statusPulse.pulseRunning
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
                    color: Theme.accent
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
