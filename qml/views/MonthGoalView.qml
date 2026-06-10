import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts

Item {
    id: root

    // MainWindow 仍绑定 onStartFocus。专注历史页不再触发它，只保留接口避免现有页面装配失败。
    signal startFocus(int taskId, string taskTitle)

    property int currentYear: new Date().getFullYear()
    property int currentMonth: new Date().getMonth() + 1
    property int selectedDay: new Date().getDate()
    property var categoryManagerRef: null
    property string loadError: ""
    property var monthSessions: []
    property var selectedDaySessions: []
    property var dailyTotals: ({})
    property int invalidSessionCount: 0

    Component.onCompleted: refresh()

    Connections {
        target: typeof focusTimer === "undefined" ? null : focusTimer
        ignoreUnknownSignals: true

        function onFocusCompleted(duration) {
            root.refresh();
        }
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

    function isoDate(value) {
        return Qt.formatDate(value, "yyyy-MM-dd");
    }

    function selectedDateKey() {
        return root.isoDate(root.dateForDay(root.selectedDay));
    }

    function dayTotalSeconds(day) {
        var total = root.dailyTotals[root.isoDate(root.dateForDay(day))];
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

    function formatClock(value) {
        if (value === undefined || value === null) {
            return "--:--";
        }

        var text = String(value).trim();
        if (text.length === 0) {
            return "--:--";
        }

        // 服务层可能返回 Qt ISODate 或 SQLite 时间文本；先按字符串截取，避免 JS Date 在不同平台解析空格格式不一致。
        var separatorIndex = text.indexOf("T");
        if (separatorIndex < 0) {
            separatorIndex = text.indexOf(" ");
        }
        if (separatorIndex >= 0 && text.length >= separatorIndex + 6) {
            var clockText = text.substring(separatorIndex + 1, separatorIndex + 6);
            if (/^\d{2}:\d{2}$/.test(clockText)) {
                return clockText;
            }
        }

        var parsed = new Date(text);
        if (!isNaN(parsed.getTime())) {
            return Qt.formatTime(parsed, "HH:mm");
        }

        return "--:--";
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
            spacing: 16

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 8
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                spacing: 4

                Text {
                    text: "专注历史"
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    color: "#5d4e37"
                }

                Text {
                    text: root.currentYear + "年" + root.currentMonth + "月"
                    font.pixelSize: 13
                    color: "#8b7355"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                spacing: 12

                Button {
                    id: previousMonthButton
                    objectName: "monthPreviousButton"
                    text: "上月"
                    implicitWidth: 72
                    implicitHeight: 40
                    background: Rectangle {
                        objectName: "monthPreviousButtonBackground"
                        color: previousMonthButton.pressed ? "#ddd4bb" : (previousMonthButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: previousMonthButton.hovered || previousMonthButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
                        radius: 8

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
                        color: "#5d4e37"
                        font.pixelSize: 13
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
                        color: currentMonthButton.pressed ? "#ddd4bb" : (currentMonthButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: currentMonthButton.hovered || currentMonthButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
                        radius: 8

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
                        color: "#5d4e37"
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        scale: currentMonthButton.pressed ? 0.96 : 1.0
                    }
                    onClicked: {
                        var today = new Date();
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
                        color: nextMonthButton.pressed ? "#ddd4bb" : (nextMonthButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: nextMonthButton.hovered || nextMonthButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
                        radius: 8

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
                        color: "#5d4e37"
                        font.pixelSize: 13
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
                        color: cleanupInvalidButton.pressed ? "#eee2c9" : (cleanupInvalidButton.hovered ? "#f5ede3" : "#fffef9")
                        border.color: cleanupInvalidButton.hovered || cleanupInvalidButton.pressed ? "#d4a574" : "#e8dfc8"
                        border.width: 1
                        radius: 8

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
                        color: "#8b7355"
                        font.pixelSize: 13
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
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.preferredHeight: 1
                color: "#e8dfc8"
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                visible: root.loadError.length > 0
                text: root.loadError
                color: "#b24f3d"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
            }

            GridLayout {
                objectName: "monthContentStack"
                // 宽屏下左右并排，避免右侧空白；窄屏下自动堆叠，防止卡片被压到不可读。
                columns: root.width >= 820 ? 2 : 1
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.bottomMargin: 24
                columnSpacing: 16
                rowSpacing: 16

                Rectangle {
                    objectName: "monthCalendarContainer"
                    Layout.fillWidth: root.width < 820
                    Layout.minimumWidth: 360
                    Layout.preferredWidth: 460
                    Layout.maximumWidth: root.width < 820 ? 100000 : 520
                    Layout.minimumHeight: 520
                    Layout.preferredHeight: 560
                    radius: 8
                    color: "#fffef9"
                    border.color: "#e8dfc8"
                    border.width: 1
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        autoPaddingEnabled: true
                        shadowEnabled: true
                        shadowColor: "#000000"
                        shadowOpacity: 0.08
                        shadowBlur: 0.14
                        shadowHorizontalOffset: 0
                        shadowVerticalOffset: 2
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 7
                            columnSpacing: 6

                            Repeater {
                                model: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    color: "#8b7355"
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 7
                            columnSpacing: 6
                            rowSpacing: 6

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
                                    property bool todayCell: {
                                        var today = new Date();
                                        return dayNumber > 0 && root.currentYear === today.getFullYear() && root.currentMonth === today.getMonth() + 1 && dayNumber === today.getDate();
                                    }

                                    objectName: dayNumber > 0 ? "monthDayCell-" + dayNumber : "monthDayCell-empty-" + index
                                    radius: 6
                                    color: {
                                        if (dayNumber <= 0)
                                            return "#faf6ee";
                                        if (dayNumber === root.selectedDay)
                                            return "#f0e6d2";
                                        if (dayMouseArea.containsMouse)
                                            return "#fffef9";
                                        return "#faf6ee";
                                    }
                                    border.color: {
                                        if (dayNumber > 0 && (dayNumber === root.selectedDay || todayCell || dayMouseArea.containsMouse))
                                            return "#d4a574";
                                        return "#e8dfc8";
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
                                        anchors.margins: 6
                                        spacing: 2

                                        Text {
                                            Layout.fillWidth: true
                                            text: dayNumber > 0 ? String(dayNumber) : ""
                                            font.pixelSize: 13
                                            font.weight: dayNumber === root.selectedDay ? Font.Bold : Font.Normal
                                            color: "#5d4e37"
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            objectName: dayNumber > 0 ? "monthDayDuration-" + dayNumber : "monthDayDuration-empty-" + index
                                            visible: dayNumber > 0 && dayDuration > 0
                                            text: root.formatDuration(dayDuration)
                                            font.pixelSize: 11
                                            font.weight: Font.Medium
                                            color: "#d4a574"
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

                Rectangle {
                    objectName: "focusTimelinePanel"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 360
                    Layout.minimumHeight: 260
                    Layout.preferredHeight: root.width >= 820 ? 560 : 360
                    radius: 8
                    color: "#fffef9"
                    border.color: "#e8dfc8"
                    border.width: 1
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        autoPaddingEnabled: true
                        shadowEnabled: true
                        shadowColor: "#000000"
                        shadowOpacity: 0.08
                        shadowBlur: 0.14
                        shadowHorizontalOffset: 0
                        shadowVerticalOffset: 2
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 14

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Text {
                                objectName: "focusTimelineTitle"
                                Layout.fillWidth: true
                                text: root.currentMonth + "月" + root.selectedDay + "日 专注记录"
                                font.pixelSize: 16
                                font.weight: Font.Bold
                                color: "#5d4e37"
                            }

                            Text {
                                text: root.selectedDaySessions.length + "次记录"
                                font.pixelSize: 13
                                color: "#8b7355"
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.selectedDaySessions.length === 0

                            Text {
                                objectName: "focusHistoryEmptyState"
                                anchors.centerIn: parent
                                text: "这一天还没有专注记录"
                                font.pixelSize: 13
                                color: "#8b7355"
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }

                        ScrollView {
                            id: timelineScrollView
                            objectName: "focusTimelineScrollView"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.selectedDaySessions.length > 0
                            clip: true
                            contentWidth: availableWidth
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ScrollBar.vertical: ScrollBar {
                                id: timelineVerticalScrollBar
                                policy: ScrollBar.AsNeeded
                                width: 8

                                contentItem: Rectangle {
                                    implicitWidth: 4
                                    radius: 2
                                    color: timelineVerticalScrollBar.pressed || timelineVerticalScrollBar.hovered ? "#d4a574" : "#e8dfc8"
                                }

                                background: Rectangle {
                                    color: "#fffef9"
                                }
                            }

                            Column {
                                id: timelineColumn
                                width: Math.max(1, timelineScrollView.availableWidth)
                                spacing: 12

                                Repeater {
                                    model: root.selectedDaySessions

                                    delegate: Item {
                                        width: timelineColumn.width
                                        height: sessionCard.height + (index < root.selectedDaySessions.length - 1 ? 14 : 0)

                                        Rectangle {
                                            visible: index < root.selectedDaySessions.length - 1
                                            x: 7
                                            y: 28
                                            width: 2
                                            height: Math.max(0, parent.height - y)
                                            radius: 1
                                            color: "#e8dfc8"
                                        }

                                        Rectangle {
                                            width: 10
                                            height: 10
                                            x: 3
                                            y: 18
                                            radius: 5
                                            color: "#d4a574"
                                            border.color: "#fffef9"
                                            border.width: 2
                                            z: 2
                                        }

                                        Rectangle {
                                            id: sessionCard
                                            objectName: "focusSessionCard-" + index
                                            x: 24
                                            width: Math.max(1, parent.width - x)
                                            height: 86
                                            radius: 6
                                            color: "#faf8f3"
                                            border.color: "#e8dfc8"
                                            border.width: 1

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.margins: 12
                                                spacing: 12

                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    Layout.alignment: Qt.AlignVCenter
                                                    spacing: 5

                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: modelData.taskTitle && String(modelData.taskTitle).length > 0 ? modelData.taskTitle : "未知任务"
                                                        font.pixelSize: 15
                                                        font.weight: Font.Medium
                                                        color: "#3d3327"
                                                        elide: Text.ElideRight
                                                    }

                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: root.formatClock(modelData.startTime) + " - " + root.formatClock(modelData.endTime)
                                                        font.pixelSize: 12
                                                        color: "#8b7355"
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                ColumnLayout {
                                                    Layout.preferredWidth: 116
                                                    Layout.maximumWidth: 140
                                                    Layout.alignment: Qt.AlignVCenter
                                                    spacing: 5

                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: root.formatDuration(Number(modelData.durationSeconds) || 0)
                                                        font.pixelSize: 18
                                                        font.weight: Font.Bold
                                                        color: "#d4a574"
                                                        horizontalAlignment: Text.AlignRight
                                                        elide: Text.ElideRight
                                                    }

                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: "已完成"
                                                        font.pixelSize: 11
                                                        font.weight: Font.Medium
                                                        color: "#4caf50"
                                                        horizontalAlignment: Text.AlignRight
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
