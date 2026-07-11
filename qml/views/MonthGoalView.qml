import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../components"
import "MonthGoalFormat.js" as MgFmt
import "../LogicalDay.js" as LogicalDay

Item {
    id: root

    // MainWindow 仍绑定 onStartFocus。专注历史页不再触发它，只保留接口避免现有页面装配失败。
    signal startFocus(int taskId, string taskTitle)

    property int currentYear: new Date().getFullYear()
    property int currentMonth: new Date().getMonth() + 1
    property int selectedDay: new Date().getDate()
    // logicalToday 必须是命令式快照；绑定会在 changed 槽保存旧值前提前重算。
    property date logicalToday
    property var logicalNowProvider: null
    property var categoryManagerRef: null
    property string loadError: ""
    property var monthSessions: []
    property var selectedDaySessions: []
    property var dailyTotals: ({})
    property int invalidSessionCount: 0

    Component.onCompleted: {
        root.logicalToday = root.computeLogicalToday()
        root.currentYear = root.logicalToday.getFullYear()
        root.currentMonth = root.logicalToday.getMonth() + 1
        root.selectedDay = root.logicalToday.getDate()
        root.refresh()
    }

    Connections {
        target: typeof focusTimer === "undefined" ? null : focusTimer
        ignoreUnknownSignals: true

        function onFocusCompleted(duration) {
            root.refresh();
        }
    }

    Connections {
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            // 只有选中日期等于旧逻辑今天时才跟随；仅比较月份会把用户从手选日期强行拉走。
            var previousLogicalToday = new Date(root.logicalToday)
            var wasFollowingCurrentDay = root.selectedDay === previousLogicalToday.getDate()
                    && root.currentMonth === previousLogicalToday.getMonth() + 1
                    && root.currentYear === previousLogicalToday.getFullYear()
            var nextLogicalToday = root.computeLogicalToday()
            root.logicalToday = nextLogicalToday
            if (wasFollowingCurrentDay) {
                root.setMonth(nextLogicalToday.getFullYear(), nextLogicalToday.getMonth() + 1,
                              nextLogicalToday.getDate())
            } else {
                root.refresh()
            }
        }
    }

    function computeLogicalToday() {
        // provider 仅用于稳定测试；生产默认读取真实本地时间。
        // qmllint disable use-proper-function
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint enable use-proper-function
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(hour, now)
    }

    function hasFocusHistoryService() {
        return typeof focusHistoryService !== "undefined" && focusHistoryService !== null;
    }

    function refresh() {
        try {
            root.loadError = "";

            if (!root.hasFocusHistoryService()) {
                root.monthSessions = [];
                root.dailyTotals = ({});
                root.selectedDaySessions = [];
                root.invalidSessionCount = 0;
                return;
            }

            root.refreshInvalidSessionCount();
            root.monthSessions = focusHistoryService.getMonthSessions(root.currentYear, root.currentMonth);
            if (typeof focusHistoryService.lastError === "function"
                    && focusHistoryService.lastError().length > 0) {
                // 服务层返回空列表不一定代表真的没有记录；数据库失败也会空，需要单独提示用户。
                root.loadError = "专注历史加载失败";
            }
            root.calculateDailyTotals();
            root.updateSelectedDaySessions();
        } catch (error) {
            root.monthSessions = [];
            root.dailyTotals = ({});
            root.selectedDaySessions = [];
            root.invalidSessionCount = 0;
            root.loadError = "专注历史加载失败";
        }
    }

    function refreshInvalidSessionCount() {
        if (!root.hasFocusHistoryService() || typeof focusHistoryService.invalidSessionCount !== "function") {
            root.invalidSessionCount = 0;
            return;
        }

        root.invalidSessionCount = Math.max(0, Number(focusHistoryService.invalidSessionCount()) || 0);
    }

    function cleanupInvalidSessions() {
        if (!root.hasFocusHistoryService() || typeof focusHistoryService.cleanupInvalidSessions !== "function") {
            return;
        }

        // 清理动作只删除 3 分钟以下的已结束记录；服务层会保护正在进行的会话。
        focusHistoryService.cleanupInvalidSessions();
        root.refresh();
    }

    function calculateDailyTotals() {
        var totals = {};

        for (var i = 0; i < root.monthSessions.length; i++) {
            var session = root.monthSessions[i];
            if (!session || !session.date) {
                continue;
            }

            // durationSeconds 来自服务层，QML 侧只做聚合；缺失或非法值按 0 处理，避免界面出现 NaN。
            var durationSeconds = Number(session.durationSeconds) || 0;
            if (!totals[session.date]) {
                totals[session.date] = 0;
            }
            totals[session.date] += durationSeconds;
        }

        root.dailyTotals = totals;
    }

    function updateSelectedDaySessions() {
        var selectedDate = root.selectedDateKey();
        var filtered = [];

        for (var i = 0; i < root.monthSessions.length; i++) {
            var session = root.monthSessions[i];
            if (session && session.date === selectedDate) {
                filtered.push(session);
            }
        }

        root.selectedDaySessions = filtered;
    }

    function daysInMonth() {
        return new Date(root.currentYear, root.currentMonth, 0).getDate();
    }

    function firstOffset() {
        // 月历按周一开头；JS getDay() 的周日为 0，需要映射到最后一列。
        var day = new Date(root.currentYear, root.currentMonth - 1, 1).getDay();
        return day === 0 ? 6 : day - 1;
    }

    function dateForDay(day) {
        return new Date(root.currentYear, root.currentMonth - 1, Math.max(1, day));
    }

    function selectedDateKey() {
        return MgFmt.isoDate(root.dateForDay(root.selectedDay));
    }

    function dayTotalSeconds(day) {
        var total = root.dailyTotals[MgFmt.isoDate(root.dateForDay(day))];
        return Number(total) || 0;
    }

    function selectedDayTotalSeconds() {
        return root.dayTotalSeconds(root.selectedDay);
    }

    function formatDuration(seconds) {
        if (root.hasFocusHistoryService()) {
            return focusHistoryService.formatDuration(seconds);
        }

        if (seconds < 60) {
            return "0分钟";
        }

        var minutes = Math.floor(seconds / 60);
        if (minutes < 60) {
            return minutes + "分钟";
        }

        var hours = Math.floor(minutes / 60);
        var remainMinutes = minutes % 60;
        return remainMinutes === 0 ? hours + "小时" : hours + "小时" + remainMinutes + "分";
    }

    function setMonth(year, month, preferredDay) {
        root.currentYear = year;
        root.currentMonth = month;

        // 切换月份默认回到 1 号；传入指定日期时也要夹紧，避免 31 号落到短月份外。
        var targetDay = preferredDay === undefined ? 1 : preferredDay;
        root.selectedDay = Math.min(Math.max(1, targetDay), root.daysInMonth());
        root.refresh();
    }

    ScrollView {
        id: pageScrollView

        anchors.fill: parent
        clip: true
        contentWidth: availableWidth

        ColumnLayout {
            width: Math.max(pageScrollView.availableWidth, 1)
            spacing: Theme.space16

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 8
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                spacing: Theme.space4

                Text {
                    text: "专注历史"
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
                    color: Theme.ink
                }

                Text {
                    text: root.currentYear + "年" + root.currentMonth + "月"
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                spacing: Theme.space12

                Button {
                    id: previousMonthButton
                    objectName: "monthPreviousButton"
                    text: "上月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthPreviousButtonBackground"
                        color: previousMonthButton.pressed ? Theme.glassHover : (previousMonthButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: previousMonthButton.hovered || previousMonthButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: Text {
                        text: previousMonthButton.text
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: previousMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        if (root.currentMonth === 1) {
                            root.setMonth(root.currentYear - 1, 12, 1);
                        } else {
                            root.setMonth(root.currentYear, root.currentMonth - 1, 1);
                        }
                    }
                }

                Button {
                    id: currentMonthButton
                    objectName: "monthCurrentButton"
                    text: "本月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthCurrentButtonBackground"
                        color: currentMonthButton.pressed ? Theme.glassHover : (currentMonthButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: currentMonthButton.hovered || currentMonthButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: Text {
                        text: currentMonthButton.text
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: currentMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        var today = root.logicalToday;
                        root.setMonth(today.getFullYear(), today.getMonth() + 1, today.getDate());
                    }
                }

                Button {
                    id: nextMonthButton
                    objectName: "monthNextButton"
                    text: "下月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthNextButtonBackground"
                        color: nextMonthButton.pressed ? Theme.glassHover : (nextMonthButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: nextMonthButton.hovered || nextMonthButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: Text {
                        text: nextMonthButton.text
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: nextMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        if (root.currentMonth === 12) {
                            root.setMonth(root.currentYear + 1, 1, 1);
                        } else {
                            root.setMonth(root.currentYear, root.currentMonth + 1, 1);
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                Button {
                    id: cleanupInvalidButton
                    objectName: "focusHistoryCleanupInvalidButton"
                    visible: root.invalidSessionCount > 0
                    text: "清理无效记录"
                    implicitWidth: 132
                    implicitHeight: 40

                    background: Rectangle {
                        objectName: "focusHistoryCleanupInvalidButtonBackground"
                        color: cleanupInvalidButton.pressed ? Theme.glassHover : (cleanupInvalidButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: cleanupInvalidButton.hovered || cleanupInvalidButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: 120
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: 120
                                easing.type: Easing.OutQuad
                            }
                        }
                    }

                    contentItem: Text {
                        text: cleanupInvalidButton.text
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    onClicked: root.cleanupInvalidSessions()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                Layout.preferredHeight: 1
                color: Theme.border
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                visible: root.loadError.length > 0
                text: root.loadError
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }

            GridLayout {
                objectName: "monthContentStack"
                // 宽屏下左右并排，避免右侧空白；窄屏下自动堆叠，防止卡片被压到不可读。
                columns: root.width >= 820 ? 2 : 1
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                Layout.bottomMargin: Theme.space24
                columnSpacing: Theme.space16
                rowSpacing: Theme.space16

                Rectangle {
                    objectName: "monthCalendarContainer"
                    Layout.fillWidth: root.width < 820
                    Layout.minimumWidth: 360
                    Layout.preferredWidth: 460
                    Layout.maximumWidth: root.width < 820 ? 100000 : 520
                    Layout.minimumHeight: 520
                    Layout.preferredHeight: 560
                    radius: Theme.radiusLg
                    color: Theme.glassCard
                    border.color: Theme.glassBorder
                    border.width: 1
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        autoPaddingEnabled: true
                        shadowEnabled: true
                        shadowColor: Theme.shadow
                        shadowOpacity: 0.08
                        shadowBlur: 0.14
                        shadowHorizontalOffset: 0
                        shadowVerticalOffset: 2
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Theme.space12
                        spacing: Theme.space8

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 7
                            columnSpacing: Theme.space8

                            Repeater {
                                model: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.Medium
                                    color: Theme.inkSoft
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 7
                            columnSpacing: Theme.space8
                            rowSpacing: Theme.space8

                            Repeater {
                                model: 42

                                Rectangle {
                                    // 固定 6 周网格，月份切换时日历高度不会跳动。
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 58
                                    property int dayNumber: {
                                        var day = index - root.firstOffset() + 1;
                                        return day >= 1 && day <= root.daysInMonth() ? day : 0;
                                    }
                                    property int dayDuration: dayNumber > 0 ? root.dayTotalSeconds(dayNumber) : 0
                                    // qmllint disable unqualified
                                    property bool todayCell: {
                                        var today = root.logicalToday;
                                        return dayNumber > 0 && root.currentYear === today.getFullYear() && root.currentMonth === today.getMonth() + 1 && dayNumber === today.getDate();
                                    }
                                    // qmllint enable unqualified

                                    objectName: dayNumber > 0 ? "monthDayCell-" + dayNumber : "monthDayCell-empty-" + index
                                    radius: Theme.radiusMd
                                    color: {
                                        if (dayNumber <= 0)
                                            return Theme.surfaceRaised;
                                        if (dayNumber === root.selectedDay)
                                            return Theme.accentSoft;
                                        if (dayMouseArea.containsMouse)
                                            return Theme.surface;
                                        return Theme.surfaceRaised;
                                    }
                                    border.color: {
                                        if (dayNumber > 0 && (dayNumber === root.selectedDay || todayCell || dayMouseArea.containsMouse))
                                            return Theme.accent;
                                        return Theme.border;
                                    }
                                    border.width: (dayNumber === root.selectedDay || todayCell) ? 2 : 1

                                    Behavior on color {
                                        ColorAnimation {
                                            duration: 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                    Behavior on border.color {
                                        ColorAnimation {
                                            duration: 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                    Behavior on border.width {
                                        NumberAnimation {
                                            duration: 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: Theme.space8
                                        spacing: Theme.hairline

                                        Text {
                                            Layout.fillWidth: true
                                            text: dayNumber > 0 ? String(dayNumber) : ""
                                            font.pixelSize: Theme.fontMd
                                            font.weight: dayNumber === root.selectedDay ? Font.Bold : Font.Normal
                                            color: Theme.ink
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            objectName: dayNumber > 0 ? "monthDayDuration-" + dayNumber : "monthDayDuration-empty-" + index
                                            visible: dayNumber > 0 && dayDuration > 0
                                            text: root.formatDuration(dayDuration)
                                            font.pixelSize: Theme.fontXs
                                            font.weight: Font.Medium
                                            color: Theme.accent
                                            elide: Text.ElideRight
                                        }
                                    }

                                    MouseArea {
                                        id: dayMouseArea
                                        anchors.fill: parent
                                        enabled: parent.dayNumber > 0
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.selectedDay = parent.dayNumber;
                                            root.updateSelectedDaySessions();
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                FocusTimeline {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 360
                    Layout.minimumHeight: 260
                    Layout.preferredHeight: root.width >= 820 ? 560 : 360
                    sessions: root.selectedDaySessions
                    selectedDay: root.selectedDay
                    currentMonth: root.currentMonth
                    viewWidth: root.width
                    formatDurationFn: root.formatDuration
                }
            }
        }
    }
}
