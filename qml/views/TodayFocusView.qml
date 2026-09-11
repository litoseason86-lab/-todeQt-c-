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
    onSelectedDateChanged: historyDate.text = root.dateKey(root.selectedDate)
    property var sessions: []
    property int totalSeconds: 0
    property int focusCount: 0
    property int pendingDeleteSessionId: -1
    property bool pendingDeleteIsRest: false
    signal deleteRequested(int sessionId, string title, bool isRest)
    // 撤销窗口内记录仍在库里，补录或修改会撞上「已经看不见」的那条记录的时间段。
    // 宿主收到这个信号后立即把待删除项落库，校验才和用户看到的列表一致。
    signal pendingDeleteFlushRequested()

    onPendingDeleteSessionIdChanged: {
        if (root.pageActive)
            root.refresh()
    }
    property string loadError: ""

    readonly property bool canEditHistory: root.hasFocusHistoryService()
                                           && typeof root.focusHistoryServiceRef.addManualSession === "function"
    readonly property bool showingToday: root.dateKey(root.selectedDate) === root.dateKey(root.logicalToday)
    // 「回到今天」只有在真的能回去时才有意义：已经在今天就不显示，
    // 但用户把日期输入改成半截无效内容时仍要留一条退路。
    readonly property bool canReturnToToday: !root.showingToday || !historyDate.valid

    // 页头右侧的次级按钮：描边 + 半透明底，与全局玻璃卡片同一套语义色。
    component HeaderButton: Button {
        id: headerButton

        implicitWidth: Math.max(76, headerButtonLabel.implicitWidth + Theme.space24)
        implicitHeight: Theme.controlHeightMd

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
            // 撤销窗口内只隐藏专注行；休息有独立 ID 空间，不能误隐藏同号休息。
            loaded = loaded.filter(function(row) {
                return Boolean(row.isRest) !== root.pendingDeleteIsRest || Number(row.id) !== root.pendingDeleteSessionId
            })
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

    // 候选任务由服务层按所选日期就近排序并截断，不再是「当天任务」，故不沿用旧名。
    function taskOptionsForDialog() {
        if (root.hasFocusHistoryService() && typeof root.focusHistoryServiceRef.getTaskOptions === "function")
            return root.focusHistoryServiceRef.getTaskOptions(root.selectedDate) || []
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
        root.pendingDeleteFlushRequested()
        var saved = sessionId > 0
                ? root.focusHistoryServiceRef.updateSession(sessionId, startDateTime, durationMinutes)
                : root.focusHistoryServiceRef.addManualSession(taskId, startDateTime, durationMinutes) > 0
        if (!saved) {
            return String(root.focusHistoryServiceRef.lastError() || qsTr("保存失败"))
        }
        root.refresh()
        return ""
    }

    function deleteSession(sessionId, isRest) {
        if (!root.canEditHistory || sessionId <= 0) {
            return
        }
        for (var i = 0; i < root.sessions.length; ++i) {
            var row = root.sessions[i]
            if (Boolean(row.isRest) === Boolean(isRest) && Number(row.id) === sessionId) {
                root.deleteRequested(sessionId, String(row.taskTitle || ""), Boolean(row.isRest))
                return
            }
        }
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
                spacing: Theme.space8

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
                        // 日期由右上角的日期控件承担，这里只留统计，避免同一信息两处两种格式。
                        text: qsTr("专注 %1 次 · %2")
                                .arg(root.focusCount)
                                .arg(root.formatDuration(root.totalSeconds))
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }
                }


                // 日期导航属于页头的次级操作，和「补录」同组排在右上角；
                // 单独占一行会在标题和内容卡之间横插一条带子，把两者的关系切断。
                PageActionButton {
                    objectName: "todayFocusReturnTodayButton"
                    Layout.alignment: Qt.AlignVCenter
                    translucent: true
                    // 已经在今天时不留一个点不动的禁用按钮，直接收起；
                    // 用户把日期改成半截无效内容时也要能退回来，所以那种情况仍然出现。
                    visible: root.canReturnToToday
                    text: qsTr("回到今天")
                    onClicked: {
                        root.showToday()
                        // 日期没变时不会发出变更信号，也需要覆盖用户尚未输完的无效内容。
                        historyDate.text = root.dateKey(root.selectedDate)
                    }
                }

                DateInput {
                    id: historyDate
                    objectName: "historyDateInput"
                    Layout.alignment: Qt.AlignVCenter
                    translucent: true
                    text: root.dateKey(root.selectedDate)
                    onEdited: {
                        var date = LogicalDay.parseIsoDate(text)
                        if (date) root.showDate(date)
                    }
                }

                HeaderButton {
                    objectName: "todayFocusAddButton"
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.canEditHistory
                    text: qsTr("补录")
                    onClicked: manualSessionDialog.openForAdd(root.dateKey(root.selectedDate),
                                                              root.taskOptionsForDialog())
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
                    manualSessionDialog.openForEdit(session, root.taskOptionsForDialog())
                }
                onDeleteRequested: function (session) {
                    root.deleteSession(Number(session.id || -1), Boolean(session.isRest))
                }
            }
        }
    }

    ManualSessionDialog {
        id: manualSessionDialog

        objectName: "todayFocusManualSessionDialog"
        parent: root
        editHandler: function (sessionId, changes) {
            if (!root.canEditHistory || typeof root.focusHistoryServiceRef.updateSessionFields !== "function")
                return qsTr("当前无法修改专注记录")
            root.pendingDeleteFlushRequested()
            var saved = manualSessionDialog.originalIsRest
                    ? root.focusHistoryServiceRef.updateRestSessionFields(sessionId, changes)
                    : root.focusHistoryServiceRef.updateSessionFields(sessionId, changes)
            if (!saved)
                return String(root.focusHistoryServiceRef.lastError() || qsTr("保存失败"))
            root.refresh()
            return ""
        }
        submitHandler: function (sessionId, startDateTime, durationMinutes, taskId) {
            return root.submitManualSession(sessionId, startDateTime, durationMinutes, taskId)
        }
    }
}
