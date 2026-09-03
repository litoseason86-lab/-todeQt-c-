pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay
import "../ScheduleWeeks.js" as ScheduleWeeks

// 待办（课表）页：按星期几循环的固定时间表。
//
// 与「本周计划」的区别在数据本身，不只是版式：本周计划里的是锚定具体日期、
// 做完就结束的任务；这里的是每周重复、按周次生效、没有完成状态的课程或日程。
// 因此两页不共用数据源，本页也不写入任何任务或专注记录。
Item {
    id: root

    // 上下文属性只在 main.qml 解包，视图内部一律消费显式引用。
    property var scheduleServiceRef: null
    property var settingsRef: null
    property var categoryManagerRef: null
    property var logicalDayServiceRef: null
    property var logicalNowProvider: null
    property bool pageActive: true

    property var entries: []
    property var periods: []
    property string loadError: ""
    // 当前正在浏览的周次。与「今天所在的周次」分开保存，用户翻到别的周时不会被刷新拉回。
    property int weekIndex: 1
    // logicalToday 是命令式快照。写成绑定会在设置变化时提前重算，
    // 让「是否正在浏览当前周」的判断失真——与 WeekPlanView 同一个坑。
    property date logicalToday

    readonly property string semesterStartDate: root.settingsRef
                                                ? String(root.settingsRef.semesterStartDate || "")
                                                : ""
    // Number(...) || 20 兜住两种情况：settingsRef 为空，以及它存在却没有这个属性
    // （离屏走查和对比度审计只注入自己关心的那几个字段）。直接取值会赋 undefined 给 int。
    readonly property int semesterWeeks: Number(root.settingsRef
                                                ? root.settingsRef.semesterWeeks : 20) || 20
    readonly property string displayMode: root.settingsRef
                                          ? String(root.settingsRef.scheduleDisplayMode || "time")
                                          : "time"
    readonly property bool showWeekend: root.settingsRef
                                        ? Boolean(root.settingsRef.scheduleShowWeekend)
                                        : true
    readonly property bool semesterConfigured: root.semesterStartDate.length > 0
    // 今天落在第几周。学期锚点没设时为 0，表示算不出来。
    readonly property int currentWeekIndex: ScheduleWeeks.weekIndexForDate(root.semesterStartDate,
                                                                          root.logicalToday)
    readonly property bool viewingCurrentWeek: root.weekIndex === root.currentWeekIndex
    // 只有正在看当前周时才高亮「今天」那一列；翻到别的周还高亮会误导。
    readonly property int highlightWeekday: {
        if (!root.viewingCurrentWeek) {
            return 0
        }
        var day = new Date(root.logicalToday).getDay()
        // JS 的 getDay() 周日是 0，课表用 1..7（周一起）。
        return day === 0 ? 7 : day
    }

    function computeLogicalToday() {
        // provider 仅用于稳定测试；生产默认读取真实本地时间。
        // qmllint disable use-proper-function
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint enable use-proper-function
        var hour = root.settingsRef ? root.settingsRef.dayStartHour : 4
        return LogicalDay.todayDate(hour, now)
    }

    function refresh() {
        if (!root.scheduleServiceRef) {
            root.entries = []
            root.periods = []
            return
        }
        try {
            root.loadError = ""
            root.entries = root.scheduleServiceRef.getEntriesForWeek(root.weekIndex)
            root.periods = root.scheduleServiceRef.getPeriods()
        } catch (error) {
            root.entries = []
            root.periods = []
            root.loadError = "课表加载失败"
        }
    }

    // 把学期锚点设成本周周一，让「今天」立刻变成第 1 周。
    // 这是首次使用时最省事的入口：多数人只想先把课排进去，不关心学期第几周。
    function anchorSemesterToThisWeek() {
        if (!root.settingsRef) {
            return
        }
        root.settingsRef.semesterStartDate = ScheduleWeeks.isoDate(
            ScheduleWeeks.mondayOf(root.logicalToday))
        root.weekIndex = 1
        root.refresh()
    }

    function goToWeek(target) {
        // 周次下界是 1：学期开始之前没有「第 0 周」可言。
        // 上界跟随学期总周数，避免一直往后翻出一片永远空白的网格。
        root.weekIndex = Math.max(1, Math.min(root.semesterWeeks, target))
        root.refresh()
    }

    Component.onCompleted: {
        root.logicalToday = root.computeLogicalToday()
        root.weekIndex = Math.max(1, root.currentWeekIndex)
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
        target: root.scheduleServiceRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onScheduleChanged() { root.refresh() }
        function onPeriodsChanged() { root.refresh() }
        function onOperationFailed(message) {
            root.loadError = String(message || "课表操作失败")
        }
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onCategoriesChanged() { root.refresh() }
    }

    Connections {
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        function onChanged() {
            // 必须先按旧快照判断跟随关系，再读新时间；顺序反转会把历史周误判成当前周。
            var wasFollowingCurrentWeek = root.viewingCurrentWeek
            root.logicalToday = root.computeLogicalToday()
            if (wasFollowingCurrentWeek) {
                root.weekIndex = Math.max(1, root.currentWeekIndex)
            }
            root.refresh()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        // —— 页头：标题、周次概览与操作区 ——
        // fillHeight 必须显式关掉：布局类型嵌在另一个布局里时该属性默认为 true，
        // 页头会跟着内容区一起瓜分纵向空间，把一行按钮拉成半屏高。
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: false
            spacing: Theme.space12

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: false
                Layout.alignment: Qt.AlignVCenter
                // 必须允许压缩到很窄：副标题是一长串中文，它的 implicitWidth 会成为
                // 整行的最小宽度，把右侧操作区顶出窗口右边缘（「添加」按钮被切掉）。
                Layout.minimumWidth: 0
                spacing: Theme.space4

                Text {
                    text: "待办"
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontXxl
                    font.bold: true
                    color: Theme.ink
                }

                Text {
                    // 副标题一眼交代三件事：现在看的是第几周、这周的日期区间、这周有几门课。
                    text: {
                        if (!root.semesterConfigured) {
                            return "尚未设置学期起始日"
                        }
                        var monday = ScheduleWeeks.mondayOfWeek(root.semesterStartDate, root.weekIndex)
                        var sunday = ScheduleWeeks.dateOfWeekday(root.semesterStartDate, root.weekIndex, 7)
                        var rangeText = monday && sunday
                            ? Qt.formatDate(monday, "M.d") + " – " + Qt.formatDate(sunday, "M.d")
                            : ""
                        var weekText = "第 " + root.weekIndex + " 周"
                        if (root.viewingCurrentWeek) {
                            weekText += "（本周）"
                        }
                        var countText = root.entries.length === 0
                            ? "本周暂无安排"
                            : "本周 " + root.entries.length + " 项"
                        return weekText + " · " + rangeText + " · " + countText
                    }
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
            }

            SegmentedSwitch {
                objectName: "scheduleModeSwitch"
                segments: ["时间轴", "节次"]
                currentIndex: root.displayMode === "period" ? 1 : 0
                minSegmentWidth: 72
                reduceMotion: Theme.reduceMotion
                solidFallback: !Theme.glassBlurAllowed
                onActivated: function (index) {
                    if (root.settingsRef) {
                        root.settingsRef.scheduleDisplayMode = index === 1 ? "period" : "time"
                    }
                }
            }

            // 周次导航收成「‹ 本周 ›」三联：三个全宽按钮（上一周/本周/下一周）
            // 在 1024 宽的默认窗口里放不下，前后翻页用箭头表达同样清楚。
            RowLayout {
                Layout.fillHeight: false
                spacing: 1

                OutlineButton {
                    objectName: "schedulePrevWeekButton"
                    text: "‹"
                    implicitWidth: 36
                    Accessible.name: "上一周"
                    enabled: root.semesterConfigured && root.weekIndex > 1
                    onClicked: root.goToWeek(root.weekIndex - 1)
                }

                OutlineButton {
                    objectName: "scheduleThisWeekButton"
                    text: "本周"
                    implicitWidth: 60
                    enabled: root.semesterConfigured && root.currentWeekIndex >= 1
                    onClicked: root.goToWeek(root.currentWeekIndex)
                }

                OutlineButton {
                    objectName: "scheduleNextWeekButton"
                    text: "›"
                    implicitWidth: 36
                    Accessible.name: "下一周"
                    enabled: root.semesterConfigured && root.weekIndex < root.semesterWeeks
                    onClicked: root.goToWeek(root.weekIndex + 1)
                }
            }

            OutlineButton {
                objectName: "scheduleSettingsButton"
                implicitWidth: 40
                Accessible.name: "课表设置"
                onClicked: settingsDialog.openDialog()

                // 文字换成图标，省下一个中文按钮的宽度；语义靠 Accessible.name 保住。
                contentItem: GlyphIcon {
                    name: "general"
                    size: 16
                    color: Theme.ink
                }
            }

            Button {
                id: addButton

                objectName: "scheduleAddButton"
                text: "添加"
                enabled: root.semesterConfigured
                implicitWidth: 72
                implicitHeight: 40

                background: Rectangle {
                    color: !addButton.enabled ? Theme.border
                           : (addButton.pressed || addButton.hovered ? Theme.accentStrong : Theme.accent)
                    radius: Theme.radiusMd

                    Behavior on color {
                        ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
                    }
                }

                contentItem: Text {
                    text: addButton.text
                    textFormat: Text.PlainText
                    // 底是实心 accent：近白字对比度只有 2.20:1，必须用专用的深色前景。
                    color: addButton.enabled ? Theme.accentForeground : Theme.inkMuted
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: entryDialog.openForNew(root.highlightWeekday > 0 ? root.highlightWeekday : 1,
                                                  8 * 60)
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
        }

        Label {
            Layout.fillWidth: true
            visible: root.loadError.length > 0
            text: root.loadError
            textFormat: Text.PlainText
            color: Theme.danger
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        // —— 首次使用引导：没有学期锚点就算不出周次，整张网格无从画起 ——
        Rectangle {
            Layout.fillWidth: true
            visible: !root.semesterConfigured
            Layout.preferredHeight: guideColumn.implicitHeight + Theme.space24 * 2
            radius: Theme.radiusLg
            color: Theme.glassCard
            border.color: Theme.glassBorder
            border.width: 1

            ColumnLayout {
                id: guideColumn

                anchors.centerIn: parent
                width: parent.width - Theme.space24 * 2
                spacing: Theme.space12

                Text {
                    Layout.fillWidth: true
                    text: "先设置学期起始日"
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    Layout.fillWidth: true
                    text: "课表按「第几周」循环，需要一个起点才能算出今天是第几周。"
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space8

                    Button {
                        id: anchorButton

                        objectName: "scheduleAnchorThisWeekButton"
                        text: "把本周设为第 1 周"
                        implicitWidth: 148
                        implicitHeight: 40

                        background: Rectangle {
                            color: anchorButton.pressed || anchorButton.hovered
                                   ? Theme.accentStrong : Theme.accent
                            radius: Theme.radiusMd

                            Behavior on color {
                                ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
                            }
                        }

                        contentItem: Text {
                            text: anchorButton.text
                            textFormat: Text.PlainText
                            color: Theme.accentForeground
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.Medium
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }

                        onClicked: root.anchorSemesterToThisWeek()
                    }

                    OutlineButton {
                        text: "手动设置"
                        implicitWidth: 88
                        onClicked: settingsDialog.openDialog()
                    }
                }
            }
        }

        // —— 节次模式下落不进任何一节的条目 ——
        // 不说出来它们就会从网格里凭空消失，用户只会以为数据丢了。
        Rectangle {
            Layout.fillWidth: true
            visible: root.semesterConfigured && scheduleGrid.unplacedEntries.length > 0
            Layout.preferredHeight: 40
            radius: Theme.radiusMd
            color: Theme.accentFill
            border.color: Theme.accent
            border.width: 1

            Text {
                anchors.fill: parent
                anchors.leftMargin: Theme.space12
                anchors.rightMargin: Theme.space12
                verticalAlignment: Text.AlignVCenter
                text: "有 " + scheduleGrid.unplacedEntries.length
                      + " 项不在任何节次内，切换到「时间轴」可以看到它们"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.accentFillInk
                elide: Text.ElideRight
            }
        }

        ScheduleGrid {
            id: scheduleGrid

            objectName: "scheduleGrid"
            visible: root.semesterConfigured
            Layout.fillWidth: true
            Layout.fillHeight: true

            entries: root.entries
            periods: root.periods
            displayMode: root.displayMode
            showWeekend: root.showWeekend
            semesterWeeks: root.semesterWeeks
            highlightWeekday: root.highlightWeekday
            semesterStartDate: root.semesterStartDate
            weekIndex: root.weekIndex

            onAddRequested: function (weekday, startMinutes) {
                entryDialog.openForNew(weekday, startMinutes)
            }

            onEditRequested: function (entryId) {
                for (var i = 0; i < root.entries.length; ++i) {
                    if (Number(root.entries[i].id) === entryId) {
                        entryDialog.openForEdit(root.entries[i])
                        return
                    }
                }
            }

            onDeleteRequested: function (entryId, title) {
                deleteConfirm.pendingId = entryId
                deleteConfirm.pendingTitle = title
                deleteConfirm.open()
            }
        }

        // 网格隐藏时（尚未设置学期锚点）由这个弹簧吃掉剩余高度，
        // 让引导卡片停在页面上方，而不是浮在一片空白的正中间。
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.semesterConfigured
        }
    }

    ScheduleEntryDialog {
        id: entryDialog

        parent: root
        scheduleServiceRef: root.scheduleServiceRef
        categoryManagerRef: root.categoryManagerRef
        semesterWeeks: root.semesterWeeks
        periods: root.periods

        onDeleteRequested: function (entryId, title) {
            deleteConfirm.pendingId = entryId
            deleteConfirm.pendingTitle = title
            deleteConfirm.open()
        }
    }

    ScheduleSettingsDialog {
        id: settingsDialog

        parent: root
        scheduleServiceRef: root.scheduleServiceRef
        settingsRef: root.settingsRef

        onSaved: {
            // 总周数调小后，当前浏览的周次可能已经越界，夹回有效范围。
            root.goToWeek(root.weekIndex)
        }
    }

    // 删除是不可逆操作，先确认再执行。
    Popup {
        id: deleteConfirm

        property int pendingId: -1
        property string pendingTitle: ""

        parent: root
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        width: Math.min(360, Math.max(260, root.width - 64))
        height: confirmColumn.implicitHeight + Theme.space24 * 2
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        padding: 0

        Overlay.modal: Rectangle {
            color: Theme.dialogScrim
        }

        background: Rectangle {
            color: Theme.glassDialog
            border.color: Theme.border
            border.width: 1
            radius: Theme.radiusLg
        }

        contentItem: ColumnLayout {
            id: confirmColumn

            spacing: Theme.space12

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.topMargin: Theme.space16
                text: "删除「" + deleteConfirm.pendingTitle + "」？"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontLg
                font.bold: true
                color: Theme.ink
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                text: "该课程会从整张课表移除，不能撤销。"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkSoft
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.bottomMargin: Theme.space16
                spacing: Theme.space8

                Item { Layout.fillWidth: true }

                OutlineButton {
                    text: "取消"
                    implicitWidth: 72
                    onClicked: deleteConfirm.close()
                }

                Button {
                    id: confirmDeleteButton

                    objectName: "scheduleConfirmDeleteButton"
                    text: "删除"
                    implicitWidth: 72
                    implicitHeight: 40

                    background: Rectangle {
                        color: confirmDeleteButton.pressed || confirmDeleteButton.hovered
                               ? Theme.danger : Theme.dangerSoft
                        radius: Theme.radiusMd

                        Behavior on color {
                            ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
                        }
                    }

                    contentItem: Text {
                        text: confirmDeleteButton.text
                        textFormat: Text.PlainText
                        color: Theme.surface
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: {
                        if (root.scheduleServiceRef && deleteConfirm.pendingId > 0) {
                            root.scheduleServiceRef.deleteEntry(deleteConfirm.pendingId)
                        }
                        deleteConfirm.close()
                    }
                }
            }
        }
    }

    // 页头与确认弹窗反复出现的次级描边按钮，抽成局部组件。
    component OutlineButton: Button {
        id: outlineButton

        implicitWidth: 76
        implicitHeight: 40

        background: Rectangle {
            color: !outlineButton.enabled ? Theme.surfaceSunken
                   : (outlineButton.pressed || outlineButton.hovered ? Theme.glassHover : Theme.glassCard)
            border.color: outlineButton.enabled && (outlineButton.hovered || outlineButton.pressed)
                          ? Theme.accent : Theme.border
            border.width: 1
            radius: Theme.radiusMd

            Behavior on color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
            }

            Behavior on border.color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
            }
        }

        contentItem: Text {
            text: outlineButton.text
            textFormat: Text.PlainText
            color: outlineButton.enabled ? Theme.ink : Theme.inkMuted
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
