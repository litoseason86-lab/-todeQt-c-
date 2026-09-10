pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

Dialog {
    id: root
    property var taskManagerRef: null
    property var categoryManagerRef: null
    property string todayIso: ""
    property int pendingDeleteTaskId: -1
    property var rows: []
    property var selectedIds: []
    property int resultLimit: 200
    property bool hasMore: false
    property string message: ""
    signal startRequested(int taskId, string title)
    title: qsTr("搜索与批量改期")
    font.pixelSize: Theme.fontMd
    standardButtons: Dialog.Close
    modal: true
    width: Math.min(760, parent ? parent.width - 32 : 760)
    height: Math.min(600, parent ? parent.height - 32 : 600)
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? (parent.height - height) / 2 : 0
    palette.highlight: Theme.focusRing
    palette.highlightedText: Theme.inputSelectedInk
    palette.text: Theme.inputInk
    palette.windowText: Theme.ink
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.window: Theme.surfaceRaised
    background: Rectangle { color: Theme.surfaceRaised; radius: Theme.radiusLg; border.color: Theme.border }
    // 与其它弹窗同一块遮罩，不用 Basic 默认的半透明黑。
    Overlay.modal: Rectangle { color: Theme.dialogScrim }

    function dateText(value) {
        return value instanceof Date ? Qt.formatDate(value, "yyyy-MM-dd") : String(value || "").substring(0, 10)
    }
    onPendingDeleteTaskIdChanged: { if (root.opened) root.refresh(false) }
    function refresh(clearSelection) {
        if (clearSelection) root.selectedIds = []
        if (root.taskManagerRef && typeof root.taskManagerRef.searchTasks === "function") {
            var result = root.taskManagerRef.searchTasks(search.text, status.currentIndex - 1, root.resultLimit)
            root.hasMore = result.length >= root.resultLimit
            root.rows = result.filter(function(row) { return Number(row.id) !== root.pendingDeleteTaskId })
            if (!clearSelection) root.selectedIds = root.pruneSelection(root.rows, root.selectedIds)
        }
    }
    // 结果集变化时保留勾选，只丢掉已经不在结果里的编号——否则在弹窗里编辑或复制一条，
    // 辛苦勾好的一批就全没了；而留下看不见的编号又会让「改期 N 项」改到列表外的任务。
    function pruneSelection(rows, ids) {
        var visible = {}
        for (var i = 0; i < rows.length; ++i) visible[Number(rows[i].id)] = true
        return ids.filter(function(id) { return visible[Number(id)] === true })
    }
    // 逾期口径以服务层为准：它排除了例行生成的实例。那些实例不参与结转，
    // 批量搬到今天会和当天新生成的实例重复。
    function selectOverdue() {
        if (!root.taskManagerRef || typeof root.taskManagerRef.getOverdueUncompletedTasks !== "function")
            return
        var overdue = root.taskManagerRef.getOverdueUncompletedTasks() || []
        var ids = {}
        for (var i = 0; i < overdue.length; ++i) ids[Number(overdue[i].id)] = true
        root.selectedIds = root.rows.filter(function(row) { return ids[Number(row.id)] === true })
                               .map(function(row) { return Number(row.id) })
    }
    function toggle(id, checked) {
        var ids = root.selectedIds.slice()
        var index = ids.indexOf(id)
        if (checked && index < 0) ids.push(id)
        if (!checked && index >= 0) ids.splice(index, 1)
        root.selectedIds = ids
    }
    function applyDate() {
        if (!targetDate.valid || root.selectedIds.length === 0 || !root.taskManagerRef) return
        var count = root.selectedIds.length
        if (root.taskManagerRef.moveTasksToDate(root.selectedIds, targetDate.text)) {
            root.message = qsTr("已将 %1 项任务移到 %2").arg(count).arg(targetDate.text)
            // 改期完成即这批操作结束，此处清空勾选；tasksChanged 触发的刷新只做保留式更新。
            root.refresh(true)
        } else {
            root.message = qsTr("改期失败，未修改任务，请刷新重试")
        }
    }
    onOpened: {
        standardButton(Dialog.Close).text = qsTr("关闭")
        targetDate.text = root.todayIso
        root.message = ""
        root.resultLimit = 200
        root.refresh(true)
        search.forceActiveFocus()
    }
    Connections {
        target: root.taskManagerRef
        ignoreUnknownSignals: true
        function onTasksChanged() { if (root.opened) root.refresh(false) }
        function onOperationFailed(message) { if (root.visible) root.message = message }
    }
    Timer { id: searchDelay; interval: 180; onTriggered: root.refresh(true) }
    contentItem: ColumnLayout {
        spacing: Theme.space8
        RowLayout {
            TextField {
                id: search
                objectName: "taskSearchField"
                Layout.fillWidth: true
                placeholderText: qsTr("搜索全部日期：标题、备注、科目")
                selectByMouse: true
                onTextEdited: { root.resultLimit = 200; root.selectedIds = []; searchDelay.restart() }
                onAccepted: { searchDelay.stop(); root.refresh(true) }
            }
            ComboBox {
                id: status
                model: [qsTr("全部状态"), qsTr("未完成"), qsTr("已完成")]
                onActivated: { root.resultLimit = 200; root.refresh(true) }
            }
        }
        RowLayout {
            PageActionButton {
                text: root.selectedIds.length === root.rows.length && root.rows.length > 0 ? qsTr("取消全选") : qsTr("全选当前结果")
                onClicked: root.selectedIds = root.selectedIds.length === root.rows.length ? [] : root.rows.map(function(row) { return Number(row.id) })
            }
            PageActionButton {
                objectName: "selectOverdueButton"
                text: qsTr("选择逾期（当前结果）")
                onClicked: root.selectOverdue()
            }
            Label { text: qsTr("已选 %1 / %2 项").arg(root.selectedIds.length).arg(root.rows.length); color: Theme.inkSoft }
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.rows
            spacing: Theme.space4
            ScrollBar.vertical: ScrollBar {}
            delegate: RowLayout {
                id: row
                required property var modelData
                width: list.width
                height: 60
                CheckBox {
                    checked: root.selectedIds.indexOf(Number(row.modelData.id)) >= 0
                    Accessible.name: qsTr("选择 %1").arg(row.modelData.title)
                    onClicked: root.toggle(Number(row.modelData.id), checked)
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Label { Layout.fillWidth: true; text: row.modelData.title; textFormat: Text.PlainText; elide: Text.ElideRight; color: Theme.ink }
                    Label {
                        Layout.fillWidth: true
                        text: root.dateText(row.modelData.date) + " · " + (row.modelData.completed ? qsTr("已完成") : qsTr("未完成")) + " · " + String(row.modelData.categoryName || "")
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Theme.inkSoft
                    }
                }
                PageActionButton { text: qsTr("开始"); onClicked: { root.close(); root.startRequested(row.modelData.id, row.modelData.title) } }
                PageActionButton { text: qsTr("编辑"); onClicked: taskEditor.openForTask(row.modelData) }
                PageActionButton {
                    text: qsTr("复制到今天")
                    onClicked: {
                        if (!root.taskManagerRef)
                            return
                        root.message = ""
                        // 失败时服务层已通过 operationFailed 写入具体原因，不能用泛化文案盖掉。
                        if (root.taskManagerRef.duplicateTask(row.modelData.id, root.todayIso))
                            root.message = qsTr("已复制到今天，完成状态与计时从零开始")
                        else if (root.message.length === 0)
                            root.message = qsTr("复制失败")
                    }
                }
            }
            Label { anchors.centerIn: parent; visible: root.rows.length === 0; text: qsTr("没有匹配任务"); color: Theme.inkSoft }
        }
        PageActionButton {
            visible: root.hasMore
            enabled: root.resultLimit < 10000
            text: root.resultLimit < 10000 ? qsTr("加载更多（已显示 %1 项）").arg(root.rows.length) : qsTr("结果过多，请缩小搜索范围")
            onClicked: { root.resultLimit = Math.min(10000, root.resultLimit + 200); root.refresh(false) }
        }
        RowLayout {
            Label { text: qsTr("移到"); color: Theme.ink }
            DateInput { id: targetDate; Layout.fillWidth: true }
            PageActionButton { text: qsTr("今天"); onClicked: targetDate.text = root.todayIso }
            PageActionButton {
                primary: true
                objectName: "batchMoveButton"
                text: qsTr("改期 %1 项").arg(root.selectedIds.length)
                enabled: root.selectedIds.length > 0 && targetDate.valid && !searchDelay.running
                onClicked: root.applyDate()
            }
        }
        Label { Layout.fillWidth: true; text: root.message; textFormat: Text.PlainText; wrapMode: Text.WordWrap; color: Theme.inkSoft }
    }
    EditTaskDialog {
        id: taskEditor
        parent: root.parent
        categoryManagerRef: root.categoryManagerRef
        taskSubmitter: function(id, title, category, date, minutes, notes) {
            return root.taskManagerRef.updateTask(id, title, category, date, minutes, notes)
        }
    }
}
