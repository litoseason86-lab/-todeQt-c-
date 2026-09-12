pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

// 日期胶囊：显示「未排期」或「9月20日 周日」，点开是常用日期 + 月历。
//
// 给「日期可以不填」的字段用（知识缺口的计划处理日期）。2026-09-11 看过设计稿后选定，
// 落选的是「DateInput + 日历按钮」。必填日期仍用 DateInput：它能手输、能逐日调整。
//
// 受控组件：自己不保存选中日期。dateIso 由调用方传入，选择只发 dateSelected(iso)，
// 由调用方决定写不写回——组件内部给 dateIso 赋值会摧毁调用方写的绑定（理由同 SegmentedSwitch）。
Button {
    id: root

    // yyyy-MM-dd；空串表示未排期。
    property string dateIso: ""
    // 逻辑今天。「今天 / 明天 / 下周一」和月历上的今天描边都以它为准：
    // 凌晨日界之前，本机的 new Date() 已经是第二天，和服务端的「今天」差一天。
    property string todayIso: ""
    property string emptyText: qsTr("未排期")

    signal dateSelected(string iso)

    // 月历正在显示的年月。month 从 0 起，与 JavaScript Date、MonthGrid 一致。
    property int shownYear: 2026
    property int shownMonth: 0
    // 键盘光标所在的日期：方向键移动，回车选中。
    property string cursorIso: ""
    // 光标描边只在用过方向键之后出现：鼠标点开日历时，今天和选中日已经各有标记，再多一圈只会添乱。
    property bool keyboardNavigating: false

    readonly property bool hasDate: LogicalDay.parseIsoDate(root.dateIso) !== null
    // 调用方没给逻辑今天（离屏预览、替身）时才退回本机日期。
    readonly property string effectiveTodayIso: LogicalDay.parseIsoDate(root.todayIso) !== null
                                                ? root.todayIso
                                                : Qt.formatDate(new Date(), "yyyy-MM-dd")
    readonly property string labelText: root.hasDate ? root.describe(root.dateIso) : root.emptyText
    readonly property bool calendarOpened: calendarPopup.opened
    property alias popup: calendarPopup
    readonly property var weekdayNames: [qsTr("周日"), qsTr("周一"), qsTr("周二"), qsTr("周三"),
                                         qsTr("周四"), qsTr("周五"), qsTr("周六")]
    readonly property var calendarLocale: Qt.locale("zh_CN")

    function pad2(value) {
        return (value < 10 ? "0" : "") + value
    }

    // 月历格子用它拼日期：直接用 MonthGrid 给的年、月、日三个整数，
    // 不经过 JavaScript Date——QDate 转成 Date 时带时区换算，可能差出一天。
    function isoOf(year, monthZeroBased, day) {
        return year + "-" + root.pad2(monthZeroBased + 1) + "-" + root.pad2(day)
    }

    // 与服务端同一口径：只接受 2000–2100 年。
    function inRange(iso) {
        var date = LogicalDay.parseIsoDate(iso)
        return date !== null && date.getFullYear() >= 2000 && date.getFullYear() <= 2100
    }

    // 按日历加减（本地时间的年月日），跨月、闰年由 Date 处理。
    function addDays(iso, days) {
        var date = LogicalDay.parseIsoDate(iso)
        if (date === null) {
            return ""
        }
        date.setDate(date.getDate() + days)
        return Qt.formatDate(date, "yyyy-MM-dd")
    }

    // 「下周一」永远在今天之后：今天就是周一时给的是下一个周一，而不是今天。
    function nextMondayIso(fromIso) {
        var date = LogicalDay.parseIsoDate(fromIso)
        if (date === null) {
            return ""
        }
        var delta = (8 - date.getDay()) % 7
        return root.addDays(fromIso, delta === 0 ? 7 : delta)
    }

    function describe(iso) {
        var date = LogicalDay.parseIsoDate(iso)
        if (date === null) {
            return root.emptyText
        }
        if (iso === root.effectiveTodayIso) {
            return qsTr("今天")
        }
        if (iso === root.addDays(root.effectiveTodayIso, 1)) {
            return qsTr("明天")
        }
        var today = LogicalDay.parseIsoDate(root.effectiveTodayIso)
        var monthDay = qsTr("%1月%2日").arg(date.getMonth() + 1).arg(date.getDate())
        // 跨年才写年份：同一年里「9月20日」就够，年份只会把胶囊撑长。
        var yearPrefix = today !== null && today.getFullYear() !== date.getFullYear()
                ? qsTr("%1年").arg(date.getFullYear()) : ""
        return yearPrefix + monthDay + " " + root.weekdayNames[date.getDay()]
    }

    function openCalendar() {
        var anchorIso = root.hasDate ? root.dateIso : root.effectiveTodayIso
        var anchor = LogicalDay.parseIsoDate(anchorIso)
        if (anchor === null) {
            return
        }
        root.shownYear = anchor.getFullYear()
        root.shownMonth = anchor.getMonth()
        root.cursorIso = anchorIso
        root.keyboardNavigating = false
        calendarPopup.open()
    }

    function closeCalendar() {
        calendarPopup.close()
    }

    function pick(iso) {
        if (iso.length > 0 && !root.inRange(iso)) {
            return
        }
        calendarPopup.close()
        root.dateSelected(iso)
    }

    function showMonth(offset) {
        var monthIndex = root.shownYear * 12 + root.shownMonth + offset
        var year = Math.floor(monthIndex / 12)
        if (year < 2000 || year > 2100) {
            return
        }
        root.shownYear = year
        root.shownMonth = monthIndex - year * 12
        root.syncCursorToShownMonth()
    }

    // 翻月之后把光标带进正在显示的月份。少了这一步，鼠标翻到 10 月、键盘按回车，
    // 提交的仍是 9 月那天——屏幕上根本看不见它；按方向键又会把月历弹回 9 月。
    // 日号在新月份里不存在时夹到月末（1 月 31 日翻到 2 月是 2 月 28 日，不是 3 月 3 日）。
    function syncCursorToShownMonth() {
        var cursor = LogicalDay.parseIsoDate(root.cursorIso)
        var day = cursor === null ? 1 : cursor.getDate()
        // 这里用 Date 只为取新月份的天数（下个月的第 0 天就是本月最后一天），
        // 不拿它拼日期：拼日期仍然走 isoOf 的三个整数，避开时区换算。
        var lastDay = new Date(root.shownYear, root.shownMonth + 1, 0).getDate()
        root.cursorIso = root.isoOf(root.shownYear, root.shownMonth, Math.min(day, lastDay))
    }

    // 光标跨月时月历跟着翻页，光标不会落到看不见的地方。
    function moveCursor(days) {
        var next = root.addDays(root.cursorIso, days)
        if (!root.inRange(next)) {
            return
        }
        var date = LogicalDay.parseIsoDate(next)
        root.cursorIso = next
        root.shownYear = date.getFullYear()
        root.shownMonth = date.getMonth()
        root.keyboardNavigating = true
    }

    objectName: "datePill"
    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: Theme.controlHeightMd
    leftPadding: Theme.space12
    // 有日期时右侧是清除钮，自带圆形命中区，胶囊右边距收窄，免得 × 离边缘太远。
    rightPadding: root.hasDate ? Theme.space4 : Theme.space12
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    Accessible.name: qsTr("计划处理日期：%1").arg(root.labelText)

    onClicked: {
        if (calendarPopup.opened) {
            calendarPopup.close()
        } else {
            root.openCalendar()
        }
    }

    // 两段细线拼成的箭头，与 DateInput 同一种画法：字体里的 ‹ › ⌄ 粗细和位置会随字体替换漂移。
    component Chevron: Item {
        id: chevron

        property real angle: 135
        property color tint: Theme.inkSoft

        implicitWidth: 10
        implicitHeight: 10

        Rectangle {
            anchors.centerIn: parent
            width: 7
            height: 7
            rotation: chevron.angle
            color: "transparent"
            Rectangle { width: 1.5; height: parent.height; radius: 0.75; color: chevron.tint }
            Rectangle { width: parent.width; height: 1.5; radius: 0.75; color: chevron.tint }
        }
    }

    component QuickChip: Button {
        id: chip

        // 「未排期」是反向操作，做成无底文字钮，和三个日期拉开分量。
        property bool quiet: false

        implicitWidth: implicitContentWidth + leftPadding + rightPadding
        implicitHeight: 28
        leftPadding: 10
        rightPadding: 10
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        Accessible.name: chip.text

        background: Rectangle {
            radius: height / 2
            color: chip.down ? Theme.surfaceSunken
                             : (chip.hovered ? Theme.glassHover
                                             : (chip.quiet ? Theme.glassHoverIdle : Theme.controlSurface))
            border.width: chip.visualFocus ? 2 : (chip.quiet ? 0 : 1)
            border.color: chip.visualFocus ? Theme.focusRing : Theme.border
        }

        contentItem: Text {
            text: chip.text
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: chip.quiet ? Theme.accentInk : Theme.ink
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component MonthStepButton: Button {
        id: stepButton

        required property int direction

        implicitWidth: 28
        implicitHeight: 28
        padding: 0
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        Accessible.name: stepButton.direction < 0 ? qsTr("上个月") : qsTr("下个月")
        onClicked: root.showMonth(stepButton.direction)

        background: Rectangle {
            radius: height / 2
            color: stepButton.down ? Theme.surfaceSunken
                                   : (stepButton.hovered ? Theme.glassHover : Theme.glassHoverIdle)
            border.width: stepButton.visualFocus ? 2 : 0
            border.color: Theme.focusRing
        }

        contentItem: Item {
            Chevron {
                anchors.centerIn: parent
                angle: stepButton.direction < 0 ? -45 : 135
                tint: stepButton.hovered || stepButton.down ? Theme.ink : Theme.inkSoft
            }
        }
    }

    background: Rectangle {
        radius: height / 2
        // 日历打开期间保持按下态：看得出弹层是从这里出来的。
        color: root.down || calendarPopup.opened
               ? Theme.surfaceSunken
               : (root.hovered ? Theme.glassHover : Theme.controlSurface)
        border.width: root.visualFocus ? 2 : 1
        border.color: root.visualFocus ? Theme.focusRing
                                       : (calendarPopup.opened ? Theme.accent : Theme.border)
    }

    contentItem: RowLayout {
        spacing: Theme.space8

        GlyphIcon {
            Layout.alignment: Qt.AlignVCenter
            name: "calendar"
            size: 16
            color: root.hasDate ? Theme.ink : Theme.inkSoft
            Accessible.ignored: true
        }

        Text {
            objectName: "datePillLabel"
            Layout.alignment: Qt.AlignVCenter
            text: root.labelText
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            color: root.hasDate ? Theme.ink : Theme.inkSoft
        }

        Chevron {
            Layout.alignment: Qt.AlignVCenter
            visible: !root.hasDate
            angle: 225
        }

        // 清除是这个字段最常用的反向操作：有日期时直接摆一个 ×，不必先打开日历再找「未排期」。
        Button {
            id: clearButton
            objectName: "datePillClearButton"

            Layout.alignment: Qt.AlignVCenter
            visible: root.hasDate
            implicitWidth: 26
            implicitHeight: 26
            padding: 0
            focusPolicy: Qt.StrongFocus
            hoverEnabled: true
            Accessible.name: qsTr("清除日期")
            onClicked: root.pick("")

            background: Rectangle {
                radius: height / 2
                color: clearButton.down ? Theme.surfaceSunken
                                        : (clearButton.hovered ? Theme.glassHover : Theme.glassHoverIdle)
                border.width: clearButton.visualFocus ? 2 : 0
                border.color: Theme.focusRing
            }

            contentItem: Item {
                Rectangle {
                    anchors.centerIn: parent
                    width: 10
                    height: 1.5
                    radius: 0.75
                    rotation: 45
                    color: clearButton.hovered ? Theme.ink : Theme.inkSoft
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 10
                    height: 1.5
                    radius: 0.75
                    rotation: -45
                    color: clearButton.hovered ? Theme.ink : Theme.inkSoft
                }
            }
        }
    }

    Popup {
        id: calendarPopup
        objectName: "datePillPopup"

        parent: root
        x: 0
        y: root.height + Theme.space8
        width: 292
        padding: Theme.space12
        // 窗口矮时弹层整体上推，不被窗口底边裁掉。
        margins: Theme.space8
        modal: false
        focus: true
        // 按在胶囊上不算「点到外面」：否则按下先关、松开又被 onClicked 重新打开，弹层会闪一下。
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.surface
            border.color: Theme.border
            border.width: 1
        }

        contentItem: ColumnLayout {
            id: calendarContent

            spacing: Theme.space8
            focus: true

            Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Left) {
                    root.moveCursor(-1)
                } else if (event.key === Qt.Key_Right) {
                    root.moveCursor(1)
                } else if (event.key === Qt.Key_Up) {
                    root.moveCursor(-7)
                } else if (event.key === Qt.Key_Down) {
                    root.moveCursor(7)
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.pick(root.cursorIso)
                } else {
                    return
                }
                event.accepted = true
            }

            RowLayout {
                spacing: Theme.space4

                QuickChip {
                    objectName: "datePillTodayChip"
                    text: qsTr("今天")
                    onClicked: root.pick(root.effectiveTodayIso)
                }

                QuickChip {
                    objectName: "datePillTomorrowChip"
                    text: qsTr("明天")
                    onClicked: root.pick(root.addDays(root.effectiveTodayIso, 1))
                }

                QuickChip {
                    objectName: "datePillNextMondayChip"
                    text: qsTr("下周一")
                    onClicked: root.pick(root.nextMondayIso(root.effectiveTodayIso))
                }

                QuickChip {
                    objectName: "datePillClearChip"
                    text: qsTr("未排期")
                    quiet: true
                    onClicked: root.pick("")
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    objectName: "datePillMonthTitle"
                    Layout.fillWidth: true
                    text: qsTr("%1 年 %2 月").arg(root.shownYear).arg(root.shownMonth + 1)
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                    color: Theme.inkStrong
                }

                MonthStepButton {
                    objectName: "datePillPreviousMonthButton"
                    direction: -1
                }

                MonthStepButton {
                    objectName: "datePillNextMonthButton"
                    direction: 1
                }
            }

            DayOfWeekRow {
                Layout.fillWidth: true
                locale: root.calendarLocale

                delegate: Text {
                    required property var model

                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: model.narrowName
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontXs
                    color: Theme.inkSoft
                }
            }

            MonthGrid {
                id: monthGrid
                objectName: "datePillMonthGrid"

                Layout.fillWidth: true
                Layout.preferredHeight: 6 * 34
                year: root.shownYear
                month: root.shownMonth
                locale: root.calendarLocale

                delegate: Item {
                    id: dayCell

                    required property var model

                    readonly property string iso: root.isoOf(dayCell.model.year, dayCell.model.month,
                                                             dayCell.model.day)
                    readonly property bool inShownMonth: dayCell.model.month === monthGrid.month
                    readonly property bool selected: dayCell.iso === root.dateIso
                    readonly property bool isToday: dayCell.iso === root.effectiveTodayIso
                    readonly property bool showCursor: root.keyboardNavigating && dayCell.iso === root.cursorIso

                    objectName: "datePillDay-" + dayCell.iso

                    Rectangle {
                        anchors.centerIn: parent
                        width: 30
                        height: 30
                        radius: 15
                        color: dayCell.selected ? Theme.accentFill
                                                : (dayHover.containsMouse ? Theme.glassHover : Theme.glassHoverIdle)
                        // 键盘光标用焦点色粗描边；今天用强调色细描边；两者都不压过选中的填充。
                        border.width: dayCell.showCursor ? 2 : (dayCell.isToday && !dayCell.selected ? 1 : 0)
                        border.color: dayCell.showCursor ? Theme.focusRing : Theme.accent
                    }

                    Text {
                        anchors.centerIn: parent
                        text: dayCell.model.day
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontSm
                        font.weight: dayCell.isToday || dayCell.selected ? Font.DemiBold : Font.Normal
                        // 相邻月份的日子弱化但仍可点：跨月选日期不必先翻页。
                        color: dayCell.selected ? Theme.accentFillInk
                                                : (dayCell.inShownMonth ? Theme.ink : Theme.inkSoft)
                        opacity: dayCell.inShownMonth || dayCell.selected ? 1 : 0.6
                    }

                    // 用 MouseArea 而不是 TapHandler：MonthGrid 自己在按下时就拿走独占抓取，
                    // 只拿到被动抓取的 TapHandler 收不稳释放事件，点一下时灵时不灵。
                    // 子项的 MouseArea 先于父控件收到事件，稳定得多。
                    MouseArea {
                        id: dayHover

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pick(dayCell.iso)
                    }
                }
            }
        }
    }
}
