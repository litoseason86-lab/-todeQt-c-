pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import ".."
import "../LogicalDay.js" as LogicalDay

// 知识缺口清单页：捕获下来的条目在这里被排期、转成任务、或者写下结论收尾。
//
// 这一页本身只是捕获和提醒两端之间的中转站。真正决定这个功能有没有用的，
// 是专注页那个不打断的捕获钮，和今日任务页那条会催人的提示条。
Item {
    id: root

    property var knowledgeGapServiceRef: null
    property var categoryManagerRef: null
    property var logicalDayServiceRef: null
    property var settingsRef: null
    // 关联任务是「还在没做完」「已完成」还是「已经被删掉」，决定行里那句提示和
    // 「今天做」能不能点。这些变化几乎都发生在别的页面，只能靠任务信号传过来。
    property var taskManagerRef: null
    // 页面容器显式声明是否当前页；不能依赖 effective visible，离屏测试和窗口层级会污染该值。
    property bool pageActive: true

    property var gaps: []
    property int statusFilter: 0
    property string searchText: ""
    property string loadError: ""
    // 逻辑今天必须是可观察状态：日界变化时要重算分组，不能依赖 new Date() 触发绑定重算。
    property string logicalTodayIso: ""

    signal gapConvertedToTask(string title)

    readonly property int statusOpen: 0
    readonly property int statusScheduled: 1
    readonly property int statusResolved: 2

    function dayStartHour() {
        // 不能写成 dayStartHour || 4：0 点是合法日界，|| 会把它当成缺值改回 4，
        // 凌晨 0–4 点「今天做」就会把任务排到前一天，和服务端的提醒口径分家。
        if (!root.settingsRef || root.settingsRef.dayStartHour === undefined
                || root.settingsRef.dayStartHour === null) {
            return 4
        }
        var hour = Number(root.settingsRef.dayStartHour)
        return isNaN(hour) ? 4 : hour
    }

    function refreshLogicalToday() {
        root.logicalTodayIso = LogicalDay.todayIso(root.dayStartHour(), new Date())
    }

    function reload() {
        if (!root.knowledgeGapServiceRef || typeof root.knowledgeGapServiceRef.listGaps !== "function") {
            root.gaps = []
            return
        }
        root.gaps = root.knowledgeGapServiceRef.listGaps(root.statusFilter, 0, root.searchText, 0)
    }

    // 分组只看服务算好的 overdue / dueToday / scheduled 三个事实，
    // 页面不自己比日期——「今天」的口径只能有一份，在 C++ 侧。
    function groupOf(gap) {
        if (Number(gap.status) === root.statusResolved) {
            return "resolved"
        }
        if (gap.overdue) {
            return "overdue"
        }
        if (gap.dueToday) {
            return "today"
        }
        return gap.scheduled ? "future" : "unscheduled"
    }

    function groupTitle(key) {
        switch (key) {
        case "overdue": return qsTr("已逾期")
        case "today": return qsTr("今天")
        case "future": return qsTr("之后")
        case "unscheduled": return qsTr("未排期")
        default: return qsTr("已解决")
        }
    }

    function gapsInGroup(key) {
        var result = []
        for (var i = 0; i < root.gaps.length; ++i) {
            if (root.groupOf(root.gaps[i]) === key) {
                result.push(root.gaps[i])
            }
        }
        return result
    }

    readonly property var groupKeys: ["overdue", "today", "future", "unscheduled", "resolved"]

    function metaTextFor(gap) {
        var parts = []
        if (gap.overdue) {
            parts.push(qsTr("已逾期 %1 天").arg(Number(gap.overdueDays)))
        } else if (gap.dueToday) {
            parts.push(qsTr("今天到期"))
        } else if (gap.scheduled) {
            parts.push(String(gap.dueDate))
        } else {
            parts.push(qsTr("未排期"))
        }
        // 只有「高」值得占一格：中是默认值，低本来就不需要催，
        // 把三档都写出来等于每行都挂一句废话。
        if (Number(gap.priority) === 2) {
            parts.push(qsTr("高优先级"))
        }
        if (String(gap.categoryName || "").length > 0) {
            parts.push(String(gap.categoryName))
        }
        if (String(gap.sourceTaskTitle || "").length > 0) {
            parts.push(qsTr("来自：%1").arg(String(gap.sourceTaskTitle)))
        }
        return parts.join(" · ")
    }

    function convertToTask(gap) {
        if (!root.knowledgeGapServiceRef || typeof root.knowledgeGapServiceRef.convertToTask !== "function") {
            root.loadError = qsTr("记录服务不可用")
            return
        }
        var taskId = Number(root.knowledgeGapServiceRef.convertToTask(gap.id, root.logicalTodayIso))
        if (taskId > 0) {
            root.gapConvertedToTask(String(gap.title))
        }
    }

    function resolveGap(gap) {
        if (root.knowledgeGapServiceRef && typeof root.knowledgeGapServiceRef.resolveGap === "function") {
            root.knowledgeGapServiceRef.resolveGap(gap.id, String(gap.resolution || ""))
        }
    }

    function reopenGap(gap) {
        if (root.knowledgeGapServiceRef && typeof root.knowledgeGapServiceRef.reopenGap === "function") {
            root.knowledgeGapServiceRef.reopenGap(gap.id)
        }
    }

    // 待确认删除的条目。暴露成页面自己的只读状态，而不是让外部去摸弹窗内部：
    // 删除这条流程的契约（「请求」不落库，「确认」才落库）属于这个页面，不属于那个弹窗。
    readonly property int pendingDeleteGapId: deleteConfirm.pendingId
    readonly property string pendingDeleteTitle: deleteConfirm.pendingTitle

    function requestDelete(gap) {
        // 删除走二次确认而不是撤销窗口：全应用的撤销窗口带着
        // 「备份 / 恢复 / 退出 / 补录之前必须先提交待删除项」这条硬约束，
        // 多接一个域就多一处会漏掉的 flush。这里条目少，确认一次更稳。
        deleteConfirm.pendingId = Number(gap.id)
        deleteConfirm.pendingTitle = String(gap.title)
        deleteConfirm.open()
    }

    function confirmPendingDelete() {
        var id = deleteConfirm.pendingId
        deleteConfirm.close()
        deleteConfirm.pendingId = -1
        deleteConfirm.pendingTitle = ""
        if (id > 0 && root.knowledgeGapServiceRef
                && typeof root.knowledgeGapServiceRef.deleteGap === "function") {
            root.knowledgeGapServiceRef.deleteGap(id)
        }
    }

    function cancelPendingDelete() {
        deleteConfirm.close()
        deleteConfirm.pendingId = -1
        deleteConfirm.pendingTitle = ""
    }

    Component.onCompleted: {
        root.refreshLogicalToday()
        root.reload()
    }

    onPageActiveChanged: if (root.pageActive) root.reload()

    Connections {
        target: root.knowledgeGapServiceRef
        ignoreUnknownSignals: true

        function onGapsChanged() {
            root.loadError = ""
            root.reload()
        }

        function onOperationFailed(message) {
            root.loadError = String(message || qsTr("知识缺口操作失败"))
        }
    }

    Connections {
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        function onChanged() {
            root.refreshLogicalToday()
            root.reload()
        }
    }

    Connections {
        target: root.settingsRef
        ignoreUnknownSignals: true

        function onDayStartHourChanged() {
            root.refreshLogicalToday()
            root.reload()
        }
    }

    RefreshCoalescer {
        id: refreshCoalescer

        active: root.pageActive
        onTriggered: root.reload()
    }

    Connections {
        // 任务被删除、完成或撤销恢复都不会让缺口服务发 gapsChanged——变的是 tasks 那张表。
        // 不接这个信号，停在本页的用户会一直对着一个禁用的「今天做」：删除任务后在 5 秒
        // 撤销窗口内切过来，删除随后真正提交，库里的关联早就清了，页面却还显示「已转成任务」。
        // 后台专注自动完成任务也是同一类。
        target: root.taskManagerRef
        ignoreUnknownSignals: true
        enabled: root.pageActive

        function onTasksChanged() {
            refreshCoalescer.request()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        RowLayout {
            Layout.fillWidth: true
            // ColumnLayout 里的子 Layout 默认 fillHeight 为 true（普通 Item 才是 false）。
            // 列表为空时它会把整块剩余高度吃掉，页头被拉到页面中间、标题和搜索框之间
            // 裂开一大段空白。这里必须显式关掉。
            Layout.fillHeight: false
            spacing: Theme.space12

            Text {
                objectName: "knowledgeGapPageTitle"
                text: qsTr("知识缺口")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXxl
                font.weight: Font.Bold
                color: Theme.ink
            }

            Item { Layout.fillWidth: true }

            SegmentedSwitch {
                objectName: "knowledgeGapStatusSwitch"
                segments: [qsTr("待处理"), qsTr("已安排"), qsTr("已解决")]
                minSegmentWidth: 76
                currentIndex: root.statusFilter
                reduceMotion: Theme.reduceMotion
                solidFallback: !Theme.glassBlurAllowed
                onActivated: function (index) {
                    root.statusFilter = index
                    root.reload()
                }
            }

            PageActionButton {
                objectName: "knowledgeGapAddButton"
                text: qsTr("新增")
                glyph: "plus"
                primary: true
                onClicked: gapDialog.openForAdd()
            }
        }

        TextField {
            id: searchField
            objectName: "knowledgeGapSearchField"
            Layout.fillWidth: true
            implicitHeight: Theme.controlHeightMd
            placeholderText: qsTr("搜索")
            selectByMouse: true
            color: Theme.inputInk
            // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
            palette.text: Theme.inputInk
            // 占位文字用 inkSoft 而不是 inkMuted：这个框常驻页面，
            // inkMuted 压在 surfaceRaised 上只有 3.1:1（夜间 3.55:1），达不到正文 4.5:1。
            // 日期输入此前正是踩了同一个坑才让对比度门禁转红。
            placeholderTextColor: Theme.inkSoft

            background: Rectangle {
                color: Theme.surfaceRaised
                radius: Theme.radiusMd
                border.color: searchField.activeFocus ? Theme.accent : Theme.border
                border.width: searchField.activeFocus ? 2 : 1
            }

            onTextChanged: {
                root.searchText = searchField.text
                root.reload()
            }
        }

        Rectangle {
            objectName: "knowledgeGapErrorBanner"
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            visible: root.loadError.length > 0
            radius: Theme.radiusMd
            color: Theme.surfaceSunken
            border.color: Theme.dangerBorder
            border.width: 1

            Text {
                anchors.fill: parent
                anchors.leftMargin: Theme.space12
                anchors.rightMargin: Theme.space12
                verticalAlignment: Text.AlignVCenter
                text: root.loadError
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.danger
                elide: Text.ElideRight
            }
        }

        // 空状态只留一行弱色文字。这一页是干什么的，用户点进来之前就知道了；
        // 在空页面上摆一张卡再讲一遍用法，是替看不懂的人操心，对真正的用户只是噪音。
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.gaps.length === 0 && root.loadError.length === 0

            Text {
                objectName: "knowledgeGapEmptyStateText"
                anchors.centerIn: parent
                text: root.searchText.length > 0 ? qsTr("没有匹配的条目") : qsTr("没有条目")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                // inkMuted 是占位/禁用级别的弱色，压在页面底色上只有 3.3:1（夜间 3.95:1），
                // 达不到正文 4.5:1。空状态这行是正文，用 inkSoft。
                color: Theme.inkSoft
            }
        }

        ScrollView {
            objectName: "knowledgeGapScrollView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.gaps.length > 0
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                width: parent ? parent.width : 0
                spacing: Theme.space16

                Repeater {
                    model: root.groupKeys

                    ColumnLayout {
                        id: groupBlock
                        required property string modelData

                        readonly property var groupGaps: root.gapsInGroup(groupBlock.modelData)

                        Layout.fillWidth: true
                        spacing: Theme.space8
                        visible: groupBlock.groupGaps.length > 0

                        Text {
                            objectName: "knowledgeGapGroupTitle-" + groupBlock.modelData
                            text: root.groupTitle(groupBlock.modelData)
                                  + " · " + groupBlock.groupGaps.length
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Bold
                            color: groupBlock.modelData === "overdue" ? Theme.danger : Theme.inkSoft
                        }

                        Repeater {
                            model: groupBlock.groupGaps

                            Rectangle {
                                id: gapRow
                                required property var modelData

                                objectName: "knowledgeGapRow-" + gapRow.modelData.id
                                Layout.fillWidth: true
                                implicitHeight: rowContent.implicitHeight + Theme.space16 * 2
                                radius: Theme.radiusMd
                                // 内容卡保持清晰，不做实时玻璃：玻璃只留给导航、工具栏和弹窗。
                                color: Theme.surfaceRaised
                                border.color: Theme.border
                                border.width: 1

                                RowLayout {
                                    id: rowContent
                                    anchors.fill: parent
                                    anchors.margins: Theme.space16
                                    spacing: Theme.space12

                                    // 科目色点始终占位，没有科目时只是不上色。
                                    // 用 visible 控制会让没有科目的那几行标题整体左移，
                                    // 一列标题左缘参差不齐，比多几个空位难看得多。
                                    //
                                    // 对齐到标题首行而不是整行垂直居中：行高会随副文行数变化，
                                    // 居中会让色点浮在标题和副文之间，看不出它在标注哪一行。
                                    Rectangle {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: 6
                                        Layout.preferredWidth: 8
                                        Layout.preferredHeight: 8
                                        radius: 4
                                        // 静态 transparent，没有 Behavior on color，不会插值出灰色中间帧。
                                        color: String(gapRow.modelData.categoryColor || "").length > 0
                                               ? String(gapRow.modelData.categoryColor)
                                               : "transparent"
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.space4

                                        Text {
                                            Layout.fillWidth: true
                                            text: String(gapRow.modelData.title)
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontMd
                                            color: Theme.ink
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: root.metaTextFor(gapRow.modelData)
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontXs
                                            color: Theme.inkMuted
                                            elide: Text.ElideRight
                                        }

                                        // 关联任务的两种事实各给一行短字，都只陈述、不替用户做决定：
                                        // 做完了不代表已经想明白，所以不自动标记已解决；没做完时说明
                                        // 「今天做」为什么点不了。原来这里写过一整句「如果确实想明白了，
                                        // 标记已解决」——该点哪个按钮旁边就摆着，不必再教一遍。
                                        Text {
                                            Layout.fillWidth: true
                                            objectName: "knowledgeGapLinkedTaskHint-" + gapRow.modelData.id
                                            visible: (Boolean(gapRow.modelData.linkedTaskCompleted)
                                                      || Boolean(gapRow.modelData.linkedTaskOpen))
                                                     && Number(gapRow.modelData.status) !== root.statusResolved
                                            text: Boolean(gapRow.modelData.linkedTaskOpen)
                                                  ? qsTr("已转成任务") : qsTr("关联任务已完成")
                                            textFormat: Text.PlainText
                                            font.pixelSize: Theme.fontXs
                                            color: Theme.accentInk
                                            elide: Text.ElideRight
                                        }
                                    }

                                    PageActionButton {
                                        objectName: "knowledgeGapConvertButton-" + gapRow.modelData.id
                                        visible: Number(gapRow.modelData.status) !== root.statusResolved
                                        // 已有没做完的任务时服务会拒绝再转，按钮不摆出注定失败的动作。
                                        enabled: !Boolean(gapRow.modelData.linkedTaskOpen)
                                        text: qsTr("今天做")
                                        onClicked: root.convertToTask(gapRow.modelData)
                                    }

                                    PageActionButton {
                                        objectName: "knowledgeGapResolveButton-" + gapRow.modelData.id
                                        text: Number(gapRow.modelData.status) === root.statusResolved
                                              ? qsTr("重新打开") : qsTr("已解决")
                                        onClicked: {
                                            if (Number(gapRow.modelData.status) === root.statusResolved) {
                                                root.reopenGap(gapRow.modelData)
                                            } else {
                                                root.resolveGap(gapRow.modelData)
                                            }
                                        }
                                    }

                                    PageActionButton {
                                        objectName: "knowledgeGapEditButton-" + gapRow.modelData.id
                                        text: qsTr("编辑")
                                        onClicked: gapDialog.openForEdit(gapRow.modelData)
                                    }

                                    PageActionButton {
                                        objectName: "knowledgeGapDeleteButton-" + gapRow.modelData.id
                                        text: qsTr("删除")
                                        onClicked: root.requestDelete(gapRow.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    KnowledgeGapDialog {
        id: gapDialog
        parent: root
        gapServiceRef: root.knowledgeGapServiceRef
        categoryManagerRef: root.categoryManagerRef
        todayIso: root.logicalTodayIso
    }

    Dialog {
        id: deleteConfirm
        objectName: "knowledgeGapDeleteConfirm"

        property int pendingId: -1
        property string pendingTitle: ""

        parent: root
        anchors.centerIn: parent
        modal: true
        width: 360
        padding: Theme.space24
        closePolicy: Popup.CloseOnEscape

        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusLg
            border.color: Theme.border
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: Theme.space12

            Text {
                Layout.fillWidth: true
                text: qsTr("删除这条知识缺口？")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
                color: Theme.inkStrong
            }

            Text {
                Layout.fillWidth: true
                objectName: "knowledgeGapDeleteConfirmText"
                text: deleteConfirm.pendingTitle
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkSoft
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("删除后无法撤销。")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.danger
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                Item { Layout.fillWidth: true }

                PageActionButton {
                    objectName: "knowledgeGapDeleteCancelButton"
                    text: qsTr("取消")
                    onClicked: root.cancelPendingDelete()
                }

                PageActionButton {
                    objectName: "knowledgeGapDeleteConfirmButton"
                    text: qsTr("删除")
                    primary: true
                    onClicked: root.confirmPendingDelete()
                }
            }
        }
    }
}
