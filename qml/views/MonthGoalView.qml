pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "MonthGoalFormat.js" as MgFmt
import "../LogicalDay.js" as LogicalDay
import "../HeatmapBands.js" as HeatmapBands

Item {
    id: root

    // 月历只选择和汇总日期；记录明细由今日专注页接管。
    signal focusDateRequested(date selectedDate)

    property int currentYear: new Date().getFullYear()
    property int currentMonth: new Date().getMonth() + 1
    property int selectedDay: new Date().getDate()
    // logicalToday 必须是命令式快照；绑定会在 changed 槽保存旧值前提前重算。
    property date logicalToday
    property var logicalNowProvider: null
    // 上下文属性只在 main.qml 解包，视图内部一律消费显式引用。
    property var focusTimerRef: null
    property var focusHistoryServiceRef: null
    property var logicalDayServiceRef: null
    property var settingsRef: null
    property var categoryManagerRef: null
    property string loadError: ""
    property var monthSessions: []
    property var dailyTotals: ({})
    property int invalidSessionCount: 0
    property bool pageActive: true

    Component.onCompleted: {
        root.logicalToday = root.computeLogicalToday()
        root.currentYear = root.logicalToday.getFullYear()
        root.currentMonth = root.logicalToday.getMonth() + 1
        root.selectedDay = root.logicalToday.getDate()
        if (root.pageActive)
            root.refresh()
    }
    onPageActiveChanged: {
        if (root.pageActive)
            root.refresh()
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onFocusCompleted(duration) {
            root.refresh();
        }
    }

    Connections {
        target: root.logicalDayServiceRef
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
                if (root.pageActive)
                    root.refresh()
            }
        }
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
        return root.focusHistoryServiceRef !== null;
    }

    function refresh() {
        try {
            root.loadError = "";

            if (!root.hasFocusHistoryService()) {
                root.monthSessions = [];
                root.dailyTotals = ({});
                root.invalidSessionCount = 0;
                return;
            }

            root.refreshInvalidSessionCount();
            root.monthSessions = root.focusHistoryServiceRef.getMonthSessions(root.currentYear, root.currentMonth);
            if (typeof root.focusHistoryServiceRef.lastError === "function"
                    && root.focusHistoryServiceRef.lastError().length > 0) {
                // 服务层返回空列表不一定代表真的没有记录；数据库失败也会空，需要单独提示用户。
                root.loadError = "专注历史加载失败";
            }
            root.calculateDailyTotals();
        } catch (error) {
            root.monthSessions = [];
            root.dailyTotals = ({});
            root.invalidSessionCount = 0;
            root.loadError = "专注历史加载失败";
        }
    }

    function refreshInvalidSessionCount() {
        if (!root.hasFocusHistoryService() || typeof root.focusHistoryServiceRef.invalidSessionCount !== "function") {
            root.invalidSessionCount = 0;
            return;
        }

        root.invalidSessionCount = Math.max(0, Number(root.focusHistoryServiceRef.invalidSessionCount()) || 0);
    }

    function cleanupInvalidSessions() {
        if (!root.hasFocusHistoryService() || typeof root.focusHistoryServiceRef.cleanupInvalidSessions !== "function") {
            return;
        }

        // 清理动作只删除 3 分钟以下的已结束记录；服务层会保护正在进行的会话。
        root.focusHistoryServiceRef.cleanupInvalidSessions();
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

    function dayTotalSeconds(day) {
        var total = root.dailyTotals[MgFmt.isoDate(root.dateForDay(day))];
        return Number(total) || 0;
    }

    function formatDuration(seconds) {
        // 必须连方法在不在一起判。只判对象非空的话，注入了一个没有 formatDuration
        // 的对象时会抛 TypeError，**下面这段专门为「服务不可用」写的兜底反而跑不到**，
        // 整个求值中断、标签变成空白。本文件另外三处（lastError / invalidSessionCount /
        // cleanupInvalidSessions）以及 TodayFocusView 里同名的这个函数都是这么写的，
        // 只有这里漏了。
        if (root.hasFocusHistoryService()
                && typeof root.focusHistoryServiceRef.formatDuration === "function") {
            return root.focusHistoryServiceRef.formatDuration(seconds);
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
                    textFormat: Text.PlainText
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
                    implicitHeight: Theme.controlHeightMd
                    background: Rectangle {
                        objectName: "monthPreviousButtonBackground"
                        color: previousMonthButton.pressed ? Theme.glassHover : (previousMonthButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: previousMonthButton.hovered || previousMonthButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 160
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: Text {
                        text: previousMonthButton.text
                        textFormat: Text.PlainText
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
                    implicitHeight: Theme.controlHeightMd
                    background: Rectangle {
                        objectName: "monthCurrentButtonBackground"
                        color: currentMonthButton.pressed ? Theme.glassHover : (currentMonthButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: currentMonthButton.hovered || currentMonthButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 160
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: Text {
                        text: currentMonthButton.text
                        textFormat: Text.PlainText
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
                    implicitHeight: Theme.controlHeightMd
                    background: Rectangle {
                        objectName: "monthNextButtonBackground"
                        color: nextMonthButton.pressed ? Theme.glassHover : (nextMonthButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: nextMonthButton.hovered || nextMonthButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 160
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 160
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: Text {
                        text: nextMonthButton.text
                        textFormat: Text.PlainText
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
                    // 两步确认：这个动作永久删除专注记录，没有撤销。应用对自己的要求
                    // 更高——删一条任务给 5 秒撤销条，恢复数据库有确认弹窗，
                    // 唯独这里是一点即删。不上模态框是因为被删的记录本来就被所有统计
                    // 排除（不足 3 分钟），分量配不上一个模态框；但也不能毫无确认。
                    property bool confirming: false

                    text: cleanupInvalidButton.confirming
                          ? "确认删除 " + root.invalidSessionCount + " 条？"
                          : "清理无效记录"
                    implicitWidth: cleanupInvalidButton.confirming ? 168 : 132
                    implicitHeight: Theme.controlHeightMd
                    Accessible.description: cleanupInvalidButton.confirming
                        ? "再次点击将永久删除这些记录，无法撤销"
                        : "清理不足 3 分钟的已结束专注记录"

                    // 移开鼠标或失焦即撤销确认态，避免一个「已武装」的删除按钮长期留在界面上。
                    onHoveredChanged: {
                        if (!cleanupInvalidButton.hovered)
                            cleanupInvalidButton.confirming = false
                    }
                    onActiveFocusChanged: {
                        if (!cleanupInvalidButton.activeFocus)
                            cleanupInvalidButton.confirming = false
                    }

                    background: Rectangle {
                        objectName: "focusHistoryCleanupInvalidButtonBackground"
                        color: cleanupInvalidButton.pressed ? Theme.glassHover : (cleanupInvalidButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: cleanupInvalidButton.hovered || cleanupInvalidButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusLg

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 120
                                easing.type: Easing.OutQuad
                            }
                        }
                        Behavior on border.color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 120
                                easing.type: Easing.OutQuad
                            }
                        }
                    }

                    contentItem: Text {
                        text: cleanupInvalidButton.text
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    onClicked: {
                        if (!cleanupInvalidButton.confirming) {
                            cleanupInvalidButton.confirming = true
                            return
                        }
                        cleanupInvalidButton.confirming = false
                        root.cleanupInvalidSessions()
                    }
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
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }

            GridLayout {
                objectName: "monthContentStack"
                // 记录明细移至独立的今日专注页；历史页只保留月度汇总月历。
                columns: 1
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                Layout.bottomMargin: Theme.space24
                columnSpacing: Theme.space16
                rowSpacing: Theme.space16

                Rectangle {
                    objectName: "monthCalendarContainer"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 360
                    Layout.preferredWidth: 760
                    Layout.maximumWidth: 100000
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
                                    id: weekdayHeader

                                    required property var modelData

                                    Layout.fillWidth: true
                                    text: weekdayHeader.modelData
                                    textFormat: Text.PlainText
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
                                    id: calendarCell

                                    required property int index

                                    // 固定 6 周网格，月份切换时日历高度不会跳动。
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 58
                                    property int dayNumber: {
                                        var day = calendarCell.index - root.firstOffset() + 1;
                                        return day >= 1 && day <= root.daysInMonth() ? day : 0;
                                    }
                                    property int dayDuration: dayNumber > 0 ? root.dayTotalSeconds(dayNumber) : 0
                                    // qmllint disable unqualified
                                    property bool todayCell: {
                                        var today = root.logicalToday;
                                        return dayNumber > 0 && root.currentYear === today.getFullYear() && root.currentMonth === today.getMonth() + 1 && dayNumber === today.getDate();
                                    }
                                    // 按逻辑今日逐格判断是否尚未到来；跨月翻到将来整月都是未来，翻回过去整月都不是。
                                    // 用年月日拼整数比，不比 Date：logicalToday 带时区换算，直接比时间戳可能差出一天。
                                    readonly property bool futureCell: {
                                        var today = root.logicalToday;
                                        var todayKey = today.getFullYear() * 10000 + (today.getMonth() + 1) * 100 + today.getDate();
                                        return dayNumber > 0 && root.currentYear * 10000 + root.currentMonth * 100 + dayNumber > todayKey;
                                    }
                                    // qmllint enable unqualified
                                    // 投入强度只由格底投入条表达，底色继续归选中 / 悬停状态。
                                    // 整格铺色会被选中态的 accentSoft 整个盖掉（4 档那天反而成了全月最浅的一格），
                                    // 且 119×78 的大格铺满色阶会压过整页。见 docs/业务规则.md「热力取档与专注历史月历的投入条」。
                                    // 传 seconds / 60 不取整：30 秒是有投入，不能画成零投入。
                                    readonly property int heatBand: HeatmapBands.bandForMinutes(dayDuration / 60)
                                    // 未来不画条（「尚未发生」），零投入画空轨道（「这天没学」），本月之外什么都没有。
                                    readonly property bool showsInvestmentBar: dayNumber > 0 && !futureCell

                                    objectName: dayNumber > 0 ? "monthDayCell-" + dayNumber : "monthDayCell-empty-" + calendarCell.index
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
                                            duration: Theme.reduceMotion ? 0 : 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                    Behavior on border.color {
                                        ColorAnimation {
                                            duration: Theme.reduceMotion ? 0 : 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                    Behavior on border.width {
                                        NumberAnimation {
                                            duration: Theme.reduceMotion ? 0 : 160
                                            easing.type: Easing.OutQuad
                                        }
                                    }

                                    // 日期与时长靠顶排，不铺满整格：铺满时 ColumnLayout 会把两行纵向摊开，
                                    // 时长那行被推到格底、贴住投入条，而且有无时长的格子日期高度会跳。
                                    ColumnLayout {
                                        objectName: calendarCell.dayNumber > 0
                                                    ? "monthDayText-" + calendarCell.dayNumber
                                                    : "monthDayText-empty-" + calendarCell.index
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: Theme.space8
                                        spacing: Theme.hairline

                                        Text {
                                            Layout.fillWidth: true
                                            text: calendarCell.dayNumber > 0 ? String(calendarCell.dayNumber) : ""
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontMd
                                            font.weight: calendarCell.dayNumber === root.selectedDay ? Font.Bold : Font.Normal
                                            color: Theme.ink
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            objectName: calendarCell.dayNumber > 0 ? "monthDayDuration-" + calendarCell.dayNumber : "monthDayDuration-empty-" + calendarCell.index
                                            visible: calendarCell.dayNumber > 0 && calendarCell.dayDuration > 0
                                            text: root.formatDuration(calendarCell.dayDuration)
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontXs
                                            font.weight: Font.Medium
                                            // 今天那一格底是 accentFill 暖罩，accentInk 压上去只有
                                            // 3.75:1；暖罩上的文字统一用 accentFillInk。
                                            color: Theme.accentFillInk
                                            elide: Text.ElideRight
                                        }
                                    }

                                    Rectangle {
                                        objectName: calendarCell.dayNumber > 0
                                                    ? "monthDayBar-" + calendarCell.dayNumber
                                                    : "monthDayBar-empty-" + calendarCell.index
                                        visible: calendarCell.showsInvestmentBar
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.margins: Theme.space8
                                        height: 8
                                        radius: height / 2
                                        color: calendarCell.heatBand === HeatmapBands.NONE
                                               ? Theme.heatmapEmptyTrack
                                               : Theme.heatmapBandColors[calendarCell.heatBand]
                                    }

                                    MouseArea {
                                        id: dayMouseArea
                                        // 离屏测试里合成鼠标事件打不进来（父链 visible 为假），
                                        // 用例靠这个名字直接触发点击，绕开可见性。
                                        objectName: calendarCell.dayNumber > 0
                                                    ? "monthDayMouseArea-" + calendarCell.dayNumber
                                                    : "monthDayMouseArea-empty-" + calendarCell.index
                                        anchors.fill: parent
                                        enabled: parent.dayNumber > 0
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.selectedDay = parent.dayNumber;
                                            root.focusDateRequested(root.dateForDay(parent.dayNumber));
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
