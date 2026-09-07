pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."
import "../components"
import "../LogicalDay.js" as LogicalDay
import "MonthGoalFormat.js" as MgFmt

// 今日专注负责单日记录的展示和维护。月历仅负责选择日期与汇总，二者不能再各自维护
// 一份时间轴，否则补录、修改和删除后的刷新时机必然漂移。
Item {
    id: root

    objectName: "todayFocusView"

    property bool pageActive: false
    property var focusTimerRef: null
    property var focusHistoryServiceRef: null
    property var logicalDayServiceRef: null
    property var settingsRef: null
    property var taskManagerRef: null
    property var logicalNowProvider: null
    // logicalToday 是命令式快照；跨逻辑日时要先保存旧值，不能让绑定抢先重算。
    property date logicalToday: new Date()
    property date selectedDate: new Date()
    property var sessions: []
    property int totalSeconds: 0
    property int focusCount: 0
    property string loadError: ""

    readonly property bool canEditHistory: root.hasFocusHistoryService()
                                           && typeof root.focusHistoryServiceRef.addManualSession === "function"
    readonly property bool showingToday: root.dateKey(root.selectedDate) === root.dateKey(root.logicalToday)

    // 页头右侧的次级按钮：描边 + 半透明底，与全局玻璃卡片同一套语义色。
    component HeaderButton: Button {
        id: headerButton

        implicitWidth: Math.max(76, headerButtonLabel.implicitWidth + Theme.space24)
        implicitHeight: 36

        background: Rectangle {
            color: headerButton.pressed || headerButton.hovered ? Theme.glassHover : Theme.glassCard
            border.color: headerButton.hovered || headerButton.pressed ? Theme.accent : Theme.border
            border.width: 1
            radius: Theme.radiusLg
        }

        contentItem: Text {
            id: headerButtonLabel
            text: headerButton.text
            textFormat: Text.PlainText
            color: Theme.ink
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Component.onCompleted: {
        root.logicalToday = root.computeLogicalToday()
        root.selectedDate = root.copyDate(root.logicalToday)
        if (root.pageActive) {
            root.refresh()
        }
    }

    onPageActiveChanged: {
        if (root.pageActive) {
            root.refresh()
        }
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onRestCompleted() {
            root.refresh()
        }

        function onFocusCompleted() {
            root.refresh()
        }
    }

    Connections {
        target: root.focusHistoryServiceRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onHistoryChanged() {
            root.refresh()
        }
    }

    Connections {
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        function onChanged() {
            var previousLogicalToday = root.copyDate(root.logicalToday)
            var wasShowingToday = root.dateKey(root.selectedDate) === root.dateKey(previousLogicalToday)
            root.logicalToday = root.computeLogicalToday()
            if (wasShowingToday) {
                root.selectedDate = root.copyDate(root.logicalToday)
            }
            if (root.pageActive) {
                root.refresh()
            }
        }
    }

    function copyDate(value) {
        return new Date(value.getFullYear(), value.getMonth(), value.getDate())
    }

    function computeLogicalToday() {
        // provider 仅用于稳定测试；生产默认读取真实本地时间。
        // qmllint disable use-proper-function
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint enable use-proper-function
        var hour = root.settingsRef ? root.settingsRef.dayStartHour : 4
        return LogicalDay.todayDate(hour, now)
    }

    function hasFocusHistoryService() {
        return root.focusHistoryServiceRef !== null
    }

    function dateKey(value) {
        return value instanceof Date && !isNaN(value.getTime()) ? MgFmt.isoDate(value) : ""
    }

    function showDate(dateValue) {
        if (!(dateValue instanceof Date) || isNaN(dateValue.getTime())) {
            return
        }
        root.selectedDate = root.copyDate(dateValue)
        if (root.pageActive) {
            root.refresh()
        }
    }

    function showToday() {
        root.showDate(root.logicalToday)
    }

    function refresh() {
        root.loadError = ""
        root.sessions = []
        root.totalSeconds = 0
        root.focusCount = 0
        if (!root.hasFocusHistoryService()) {
            return
        }

        try {
            var loaded = (typeof root.focusHistoryServiceRef.getDayTimeline === "function"
                          ? root.focusHistoryServiceRef.getDayTimeline(root.selectedDate)
                          : root.focusHistoryServiceRef.getDaySessions(root.selectedDate)) || []
            root.sessions = loaded
            for (var i = 0; i < loaded.length; ++i) {
                // 时间轴包含休息，但页头次数和时长始终只统计专注。
                if (!loaded[i].isRest) {
                    root.totalSeconds += Math.max(0, Number(loaded[i].durationSeconds) || 0)
                    ++root.focusCount
                }
            }
            if (typeof root.focusHistoryServiceRef.lastError === "function"
                    && root.focusHistoryServiceRef.lastError().length > 0) {
                root.loadError = qsTr("专注记录加载失败")
            }
        } catch (error) {
            root.sessions = []
            root.totalSeconds = 0
            root.focusCount = 0
            root.loadError = qsTr("专注记录加载失败")
        }
    }

    function tasksForSelectedDate() {
        if (!root.taskManagerRef || typeof root.taskManagerRef.getTasksByDate !== "function") {
            return []
        }
        var rows = root.taskManagerRef.getTasksByDate(root.dateKey(root.selectedDate)) || []
        var options = []
        for (var i = 0; i < rows.length; ++i) {
            options.push({ id: Number(rows[i].id), title: String(rows[i].title || "") })
        }
        return options
    }

    function submitManualSession(sessionId, startDateTime, durationMinutes, taskId) {
        if (!root.canEditHistory) {
            return qsTr("当前无法修改专注记录")
        }
        var saved = sessionId > 0
                ? root.focusHistoryServiceRef.updateSession(sessionId, startDateTime, durationMinutes)
                : root.focusHistoryServiceRef.addManualSession(taskId, startDateTime, durationMinutes) > 0
        if (!saved) {
            return String(root.focusHistoryServiceRef.lastError() || qsTr("保存失败"))
        }
        root.refresh()
        return ""
    }

    function deleteSession(sessionId) {
        if (!root.canEditHistory || sessionId <= 0) {
            return
        }
        if (!root.focusHistoryServiceRef.deleteSession(sessionId)) {
            root.loadError = String(root.focusHistoryServiceRef.lastError() || qsTr("删除失败"))
            return
        }
        root.refresh()
    }

    function formatDuration(seconds) {
        if (root.hasFocusHistoryService()
                && typeof root.focusHistoryServiceRef.formatDuration === "function") {
            return root.focusHistoryServiceRef.formatDuration(seconds)
        }
        var minutes = Math.floor(Math.max(0, Number(seconds) || 0) / 60)
        if (minutes < 60) {
            return qsTr("%1分钟").arg(minutes)
        }
        var hours = Math.floor(minutes / 60)
        var remainingMinutes = minutes % 60
        return remainingMinutes === 0
               ? qsTr("%1小时").arg(hours)
               : qsTr("%1小时%2分").arg(hours).arg(remainingMinutes)
    }

    function dateLabel() {
        return qsTr("%1年%2月%3日")
                .arg(root.selectedDate.getFullYear())
                .arg(root.selectedDate.getMonth() + 1)
                .arg(root.selectedDate.getDate())
    }

    ScrollView {
        id: pageScrollView

        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: Math.max(1, pageScrollView.availableWidth)
            spacing: Theme.space16

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.space8
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                spacing: Theme.space12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space4

                    Text {
                        objectName: "todayFocusPageTitle"
                        Layout.fillWidth: true
                        text: root.showingToday ? qsTr("今日专注") : qsTr("专注记录")
                        textFormat: Text.PlainText
                        color: Theme.ink
                        font.pixelSize: Theme.fontXxl
                        font.weight: Font.Bold
                    }

                    Text {
                        objectName: "todayFocusDateLabel"
                        Layout.fillWidth: true
                        text: qsTr("%1 · 共 %2 次 · %3")
                                .arg(root.dateLabel())
                                .arg(root.focusCount)
                                .arg(root.formatDuration(root.totalSeconds))
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }
                }

                HeaderButton {
                    objectName: "todayFocusReturnTodayButton"
                    visible: !root.showingToday
                    text: qsTr("回到今天")
                    onClicked: root.showToday()
                }

                HeaderButton {
                    objectName: "todayFocusAddButton"
                    visible: root.canEditHistory
                    text: qsTr("补录")
                    onClicked: manualSessionDialog.openForAdd(root.dateKey(root.selectedDate),
                                                              root.tasksForSelectedDate())
                }
            }

            Text {
                objectName: "todayFocusLoadError"
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                visible: root.loadError.length > 0
                text: root.loadError
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }

            FocusTimeline {
                id: focusTimeline
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                Layout.minimumHeight: 360
                Layout.preferredHeight: Math.max(420, root.height - 156)
                editable: root.canEditHistory
                // 表头（日期/次数/补录）已由页头承担，卡片再显示一遍就是重复信息。
                headerVisible: false
                sessions: root.sessions
                selectedDay: root.selectedDate.getDate()
                currentMonth: root.selectedDate.getMonth() + 1
                viewWidth: root.width
                formatDurationFn: root.formatDuration
                onEditRequested: function (session) {
                    manualSessionDialog.openForEdit(session, root.tasksForSelectedDate())
                }
                onDeleteRequested: function (session) {
                    root.deleteSession(Number(session.id || -1))
                }
            }
        }
    }

    ManualSessionDialog {
        id: manualSessionDialog

        objectName: "todayFocusManualSessionDialog"
        parent: root
        submitHandler: function (sessionId, startDateTime, durationMinutes, taskId) {
            return root.submitManualSession(sessionId, startDateTime, durationMinutes, taskId)
        }
    }
}
