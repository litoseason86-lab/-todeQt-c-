import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    width: 208
    readonly property color sidebarGradientTopColor: Theme.surfaceRaised
    readonly property color sidebarGradientBottomColor: Theme.surfaceSunken
    // 悬停反馈靠“边框浮现”表达：idle 与 hover 的底色都用 surfaceRaised，
    // 区别在于 hover 时 border 由隐形（同底色、宽度 0）变为 Theme.border、宽度 1。
    // 所以这里 idle/hover 底色相同不是笔误，别为了“让它们不一样”而改动。
    readonly property color sidebarItemIdleColor: Theme.surfaceRaised
    readonly property color sidebarItemIdleBorderColor: Theme.surfaceRaised
    readonly property color sidebarItemHoverColor: Theme.surfaceRaised
    readonly property color sidebarItemHoverBorderColor: Theme.border
    readonly property color sidebarItemActiveColor: Theme.accentSoft
    readonly property color sidebarItemActiveBorderColor: Theme.accent

    gradient: Gradient {
        orientation: Gradient.Vertical

        GradientStop {
            position: 0
            color: root.sidebarGradientTopColor
        }

        GradientStop {
            position: 1
            color: root.sidebarGradientBottomColor
        }
    }

    property string currentView: "today"
    property var categoryManagerRef: null
    property var exportServiceRef: null
    property var focusTimerRef: null
    signal itemClicked(string viewName)
    signal dailyRoutineRequested
    signal categoryManagementRequested
    signal dataExportRequested

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
        // 不能把非激活状态设为 transparent：hover 退场时 ColorAnimation 会做透明插值，
        // macOS 上会短暂露出灰色过渡块。默认态固定为不透明暖色，彻底切断灰闪来源。
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

            Text {
                objectName: "sidebarStatus-" + item.marker
                text: item.statusText
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
                color: Theme.accent
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
