pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../ScheduleWeeks.js" as ScheduleWeeks

// 课表周网格：左侧时间/节次刻度，右侧七列（或五列）日期。
// 两种版式共用同一份数据与同一套列结构，只有「一块课放在纵向什么位置」不同：
//   time   —— 按真实时长成比例定位，长课高、短会矮，一眼看出负载分布
//   period —— 按节次等高定位，像学校印的那种课表
Item {
    id: root

    // 已按当前周次筛选过的课表项；本组件不做周次过滤。
    property var entries: []
    property var periods: []
    property string displayMode: "time"
    property bool showWeekend: true
    property int semesterWeeks: 20
    // 1..7 表示该列是「今天」，0 表示当前显示的不是本周。
    property int highlightWeekday: 0
    // 第 weekIndex 周的每一天日期，用于列头显示 M/d；为空则只显示星期。
    property string semesterStartDate: ""
    property int weekIndex: 1

    signal addRequested(int weekday, int startMinutes)
    signal editRequested(int entryId)
    signal deleteRequested(int entryId, string title)

    readonly property var weekdayGlyphs: ["一", "二", "三", "四", "五", "六", "日"]
    readonly property int visibleDayCount: root.showWeekend ? 7 : 5
    readonly property int gutterWidth: 52
    readonly property int headerHeight: 52
    // 时间轴模式下每分钟占多少像素。0.9 让一天 14 小时约 756 像素——
    // 比一屏略高，滚动一点点就能看全，同时 45 分钟的课仍有约 40 像素可读高度。
    readonly property real pixelsPerMinute: 0.9
    readonly property int periodRowHeight: 64
    readonly property int periodRowSpacing: Theme.space4
    // 顶部留白。首个整点刻度的文字以刻度线为中心上下各占一半，
    // 不留这段空白它的上半截会被滚动区的上边缘切掉。
    readonly property int axisTopInset: 8

    // —— 时间轴模式的纵向范围 ——
    // 按当天真实排课范围裁剪，而不是固定 0–24 点：没人愿意为了看两节课先滚过八小时空白。
    // 同时兜住 8:00–22:00，让空课表也有一张像样的网格而不是塌成一条线。
    readonly property int axisStartMinutes: {
        var earliest = 8 * 60
        for (var i = 0; i < root.entries.length; ++i) {
            earliest = Math.min(earliest, Number(root.entries[i].startMinutes))
        }
        // 向下取整到整点，刻度线才落在 8:00 而不是 8:05 这种位置。
        return Math.max(0, Math.floor(earliest / 60) * 60)
    }
    readonly property int axisEndMinutes: {
        var latest = 22 * 60
        for (var i = 0; i < root.entries.length; ++i) {
            latest = Math.max(latest, Number(root.entries[i].endMinutes))
        }
        return Math.min(24 * 60, Math.ceil(latest / 60) * 60)
    }
    readonly property int axisHourCount: Math.max(1, (root.axisEndMinutes - root.axisStartMinutes) / 60)

    // 网格内容高度。两种模式各自算，滚动区据此决定要不要出现滚动条。
    readonly property int bodyHeight: root.displayMode === "period"
        ? Math.max(root.periodRowHeight,
                   root.periods.length * (root.periodRowHeight + root.periodRowSpacing)
                   - root.periodRowSpacing)
        : Math.round((root.axisEndMinutes - root.axisStartMinutes) * root.pixelsPerMinute)

    // 每一天的重叠排布结果，索引 0~6 对应周一~周日。
    // 一次性算好存进属性，避免每个 delegate 各自再跑一遍排布。
    readonly property var dayLayouts: {
        var result = []
        for (var weekday = 1; weekday <= 7; ++weekday) {
            var dayEntries = []
            for (var i = 0; i < root.entries.length; ++i) {
                if (Number(root.entries[i].weekday) === weekday) {
                    dayEntries.push(root.entries[i])
                }
            }
            result.push(ScheduleWeeks.layoutDayEntries(dayEntries))
        }
        return result
    }

    // 节次模式下落不进任何一节的课表项。它们必须被显式说出来——
    // 一门 12:30 的会议在没有对应节次时会从网格里彻底消失，
    // 用户只会以为数据丢了，而不会想到是节次表没覆盖那个时段。
    readonly property var unplacedEntries: {
        if (root.displayMode !== "period") {
            return []
        }
        var unplaced = []
        for (var i = 0; i < root.entries.length; ++i) {
            var entry = root.entries[i]
            var placed = false
            for (var j = 0; j < root.periods.length; ++j) {
                var period = root.periods[j]
                if (Number(entry.startMinutes) < Number(period.endMinutes)
                        && Number(entry.endMinutes) > Number(period.startMinutes)) {
                    placed = true
                    break
                }
            }
            if (!placed) {
                unplaced.push(entry)
            }
        }
        return unplaced
    }

    // 课表项在节次模式下跨越的行区间。返回 { first, last }，未命中任何节次时 first = -1。
    function periodRowRange(entry) {
        var first = -1
        var last = -1
        for (var i = 0; i < root.periods.length; ++i) {
            var period = root.periods[i]
            if (Number(entry.startMinutes) < Number(period.endMinutes)
                    && Number(entry.endMinutes) > Number(period.startMinutes)) {
                if (first < 0) {
                    first = i
                }
                last = i
            }
        }
        return { first: first, last: last }
    }

    function blockTop(entry) {
        if (root.displayMode === "period") {
            var range = root.periodRowRange(entry)
            if (range.first < 0) {
                return 0
            }
            return range.first * (root.periodRowHeight + root.periodRowSpacing)
        }
        return Math.round((Number(entry.startMinutes) - root.axisStartMinutes)
                          * root.pixelsPerMinute)
    }

    function blockHeight(entry) {
        if (root.displayMode === "period") {
            var range = root.periodRowRange(entry)
            if (range.first < 0) {
                return 0
            }
            var rows = range.last - range.first + 1
            return rows * (root.periodRowHeight + root.periodRowSpacing) - root.periodRowSpacing
        }
        // 极短的条目也要留出可点击的最小高度，否则 10 分钟的项几乎点不中。
        return Math.max(24, Math.round((Number(entry.endMinutes) - Number(entry.startMinutes))
                                       * root.pixelsPerMinute))
    }

    // 空白处点击新增时，用点击位置反推一个合理的起始时间。
    function minutesAtOffset(offsetY) {
        if (root.displayMode === "period") {
            var index = Math.floor(offsetY / (root.periodRowHeight + root.periodRowSpacing))
            if (index >= 0 && index < root.periods.length) {
                return Number(root.periods[index].startMinutes)
            }
            return root.periods.length > 0 ? Number(root.periods[0].startMinutes) : 8 * 60
        }
        var minutes = root.axisStartMinutes + Math.round(offsetY / root.pixelsPerMinute)
        // 对齐到 5 分钟，避免点出 09:37 这种起始时间。
        return Math.max(0, Math.min(24 * 60 - 5, Math.round(minutes / 5) * 5))
    }

    // 内容底板。课表是成片的信息，直接画在壁纸上时刻度线与山水画抢注意力、
    // 课程块也没有可依托的背景。这里铺一层玻璃纸面把网格托住——
    // 项目规则允许内容区用半透明色块透壁纸，只是不做实时模糊。
    GlassPanel {
        anchors.fill: parent
        solidFallback: !Theme.glassBlurAllowed
        panelShadowEnabled: false
        bottomRimEnabled: true
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space12
        spacing: 0

        // —— 列头：星期与日期，固定在顶部不随内容滚动 ——
        // fillHeight 必须显式关掉：布局类型（RowLayout/ColumnLayout）嵌在另一个布局里时
        // 该属性默认为 true，列头会和下面的网格一起瓜分纵向空间，把整页撑成七根大色条。
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: false
            Layout.preferredHeight: root.headerHeight
            Layout.maximumHeight: root.headerHeight
            spacing: Theme.space4

            Item {
                Layout.preferredWidth: root.gutterWidth
                Layout.fillHeight: true
            }

            Repeater {
                model: root.visibleDayCount

                Rectangle {
                    id: dayHeader

                    required property int index
                    readonly property int weekday: dayHeader.index + 1
                    readonly property bool isToday: root.highlightWeekday === dayHeader.weekday
                    readonly property var columnDate: ScheduleWeeks.dateOfWeekday(
                                                          root.semesterStartDate,
                                                          root.weekIndex,
                                                          dayHeader.weekday)

                    objectName: "scheduleDayHeader-" + dayHeader.weekday
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Theme.radiusMd
                    // 七张并排的描边卡片会在纸面上排出一条很吵的色带。
                    // 平时留白，只有「今天」用一颗淡罩胶囊标出来——
                    // 页面上同一时刻只该有一个视觉焦点。
                    color: dayHeader.isToday ? Theme.accentFill : "transparent"
                    border.color: dayHeader.isToday ? Theme.accentStrong : "transparent"
                    border.width: dayHeader.isToday ? 1 : 0

                    Column {
                        anchors.centerIn: parent
                        spacing: 1

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.weekdayGlyphs[dayHeader.index]
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontLg
                            font.bold: true
                            // 今天用淡罩底配深焦糖字；近白的 surface 在这个底上会消失。
                            color: dayHeader.isToday ? Theme.accentFillInk
                                                     : (dayHeader.weekday >= 6 ? Theme.inkSoft : Theme.ink)
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: dayHeader.columnDate !== null
                            text: dayHeader.columnDate
                                  ? Qt.formatDate(dayHeader.columnDate, "M/d") : ""
                            textFormat: Text.PlainText
                            font.family: Theme.fontFamilyClock
                            font.pixelSize: Theme.fontXs
                            color: dayHeader.isToday ? Theme.accentFillInk : Theme.inkSoft
                        }
                    }
                }
            }
        }

        // 列头与网格主体之间的分隔线。原先靠每列各自描边来区分，
        // 七条竖框加七条横框在壁纸上过密；一条横线足够交代层次。
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.space8
        }

        // —— 网格主体：纵向滚动，刻度与列一起滚 ——
        Flickable {
            id: bodyFlickable

            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: root.bodyHeight + root.axisTopInset
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ScrollBar.vertical: ScrollBar {
                id: gridScrollBar

                policy: ScrollBar.AsNeeded
                width: 8

                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: Theme.radiusSm
                    color: gridScrollBar.pressed || gridScrollBar.hovered ? Theme.accent : Theme.border
                }

                background: Rectangle {
                    // 主容器透明后轨道必须跟着透明，否则是一条压在壁纸上的白带。
                    color: "transparent"
                }
            }

            Item {
                id: body

                width: bodyFlickable.width
                height: root.bodyHeight + root.axisTopInset

                // 时间轴模式的整点横线。画在最底层，课程块压在它上面。
                // 这里的 y 要自己加上顶部留白：横线是 body 的直接子项，
                // 不像下面的列那样已经被 RowLayout 的 topMargin 推下去了。
                Repeater {
                    model: root.displayMode === "time" ? root.axisHourCount + 1 : 0

                    Rectangle {
                        required property int index

                        x: root.gutterWidth
                        width: Math.max(0, body.width - root.gutterWidth)
                        y: root.axisTopInset + Math.round(index * 60 * root.pixelsPerMinute)
                        height: 1
                        // 刻度线是参考线不是内容，压到很淡；否则一屏十几条横线
                        // 会比课程块本身还显眼。
                        color: Theme.borderSubtle
                        opacity: 0.55
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.topMargin: root.axisTopInset
                    spacing: Theme.space4

                    // 左侧刻度：时间轴模式显示整点，节次模式显示第几节与起止时间。
                    Item {
                        Layout.preferredWidth: root.gutterWidth
                        Layout.fillHeight: true

                        Repeater {
                            model: root.displayMode === "time" ? root.axisHourCount + 1 : 0

                            Text {
                                required property int index

                                x: 0
                                y: Math.round(index * 60 * root.pixelsPerMinute) - height / 2
                                width: root.gutterWidth - Theme.space8
                                horizontalAlignment: Text.AlignRight
                                text: ScheduleWeeks.formatMinutes(root.axisStartMinutes + index * 60)
                                textFormat: Text.PlainText
                                font.family: Theme.fontFamilyClock
                                font.pixelSize: Theme.fontXs
                                color: Theme.inkSoft
                            }
                        }

                        Repeater {
                            model: root.displayMode === "period" ? root.periods : []

                            Rectangle {
                                id: periodTick

                                required property int index
                                required property var modelData

                                x: 0
                                y: periodTick.index * (root.periodRowHeight + root.periodRowSpacing)
                                width: root.gutterWidth - Theme.space4
                                height: root.periodRowHeight
                                radius: Theme.radiusSm
                                color: Theme.glassCard
                                border.color: Theme.glassBorder
                                border.width: 1

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 1

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: String(periodTick.modelData.index)
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontMd
                                        font.bold: true
                                        color: Theme.ink
                                    }

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: ScheduleWeeks.formatMinutes(periodTick.modelData.startMinutes)
                                        textFormat: Text.PlainText
                                        font.family: Theme.fontFamilyClock
                                        font.pixelSize: 9
                                        color: Theme.inkSoft
                                    }
                                }
                            }
                        }
                    }

                    // —— 七（或五）列日期 ——
                    Repeater {
                        model: root.visibleDayCount

                        Item {
                            id: dayColumn

                            required property int index
                            readonly property int weekday: dayColumn.index + 1
                            readonly property var layoutItems: root.dayLayouts[dayColumn.index]

                            objectName: "scheduleDayColumn-" + dayColumn.weekday
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            // 列底：周末用极淡的暖色底区分，且不依赖颜色单独表意——
                            // 列头的星期字本身已经说明了是周六周日。
                            // 不再描边：七条竖框叠在刻度横线上会织成一张网，
                            // 列与列之间靠 spacing 和下面那条细分隔线就够分开了。
                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.radiusMd
                                color: dayColumn.weekday >= 6 ? Theme.surfaceSunken : "transparent"
                                opacity: 0.45
                            }

                            // 列之间的细分隔线。只画在左侧且跳过第一列，
                            // 避免和相邻列各画一条叠成双线。
                            Rectangle {
                                visible: dayColumn.index > 0
                                x: -Math.round(Theme.space4 / 2)
                                y: 0
                                width: 1
                                height: dayColumn.height
                                color: Theme.borderSubtle
                                opacity: 0.6
                            }

                            // 空白处点击 = 在该时段新增课程。
                            TapHandler {
                                onTapped: function (eventPoint) {
                                    root.addRequested(dayColumn.weekday,
                                                      root.minutesAtOffset(eventPoint.position.y))
                                }
                            }

                            Repeater {
                                model: dayColumn.layoutItems

                                ScheduleEntryBlock {
                                    id: entryBlock

                                    required property var modelData

                                    readonly property var entry: entryBlock.modelData.entry
                                    // 同一簇内重叠的课并排放，谁也不盖住谁。
                                    readonly property real laneWidth:
                                        Math.max(1, (dayColumn.width - 4)
                                                 / Math.max(1, entryBlock.modelData.laneCount))

                                    visible: root.blockHeight(entryBlock.entry) > 0
                                    x: 2 + entryBlock.modelData.lane * entryBlock.laneWidth
                                    width: Math.max(1, entryBlock.laneWidth - 2)
                                    y: root.blockTop(entryBlock.entry)
                                    height: root.blockHeight(entryBlock.entry)

                                    entryId: Number(entryBlock.entry.id)
                                    title: String(entryBlock.entry.title)
                                    location: String(entryBlock.entry.location || "")
                                    startMinutes: Number(entryBlock.entry.startMinutes)
                                    endMinutes: Number(entryBlock.entry.endMinutes)
                                    weekStart: Number(entryBlock.entry.weekStart)
                                    weekEnd: Number(entryBlock.entry.weekEnd)
                                    weekParity: Number(entryBlock.entry.weekParity)
                                    semesterWeeks: root.semesterWeeks
                                    categoryColor: String(entryBlock.entry.categoryColor || "")

                                    onEditRequested: function (id) { root.editRequested(id) }
                                    onDeleteRequested: function (id, title) {
                                        root.deleteRequested(id, title)
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
