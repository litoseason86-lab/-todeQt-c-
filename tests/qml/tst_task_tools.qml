pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "TaskTools"
    when: windowShown
    width: 960
    height: 720
    QtObject {
        id: manager
        signal tasksChanged()
        signal operationFailed(string message)
        property bool succeeds: true
        property bool hideSecond: false
        property var lastIds: []
        property string lastDate: ""
        function searchTasks(text, status, limit) {
            var rows = [{id: 1, title: "数学", notes: "第20页", date: new Date(2026, 5, 1), completed: false, categoryName: "数学"},
                        {id: 2, title: "英语", notes: "", date: new Date(2026, 8, 9), completed: true, categoryName: "英语"}]
            return manager.hideSecond ? [rows[0]] : rows
        }
        // 服务层的逾期口径排除例行生成的实例，这里只回 1 号。
        function getOverdueUncompletedTasks() { return [{id: 1}] }
        function moveTasksToDate(ids, date) {
            lastIds = ids.slice()
            lastDate = date
            if (succeeds) tasksChanged()
            return succeeds
        }
    }
    TaskToolsDialog {
        id: dialog
        parent: testCase
        taskManagerRef: manager
        todayIso: "2026-09-09"
    }
    function init() {
        manager.succeeds = true
        manager.hideSecond = false
        manager.lastIds = []
        manager.lastDate = ""
        dialog.pendingDeleteTaskId = -1
        dialog.open()
        tryCompare(dialog, "opened", true)
    }
    function cleanup() { dialog.close() }
    function test_datesFromBackendAndSelection() {
        compare(dialog.dateText(new Date(2026, 5, 1)), "2026-06-01")
        dialog.toggle(1, true)
        dialog.toggle(1, true)
        compare(dialog.selectedIds.length, 1)
        dialog.applyDate()
        compare(manager.lastIds.length, 1)
        compare(manager.lastIds[0], 1)
        compare(manager.lastDate, "2026-09-09")
        compare(dialog.selectedIds.length, 0)
    }
    function test_failurePreservesSelection() {
        manager.succeeds = false
        dialog.toggle(1, true)
        dialog.applyDate()
        compare(dialog.selectedIds.length, 1)
        verify(dialog.message.indexOf("失败") >= 0)
    }
    function test_selectionSurvivesTaskChangesAndDropsMissingRows() {
        dialog.toggle(1, true)
        dialog.toggle(2, true)
        // 在弹窗里编辑或复制一条会触发 tasksChanged，此时不能把辛苦勾好的一批清空。
        manager.tasksChanged()
        compare(dialog.selectedIds.length, 2)
        // 但已经不在结果里的编号必须丢掉，否则「改期 N 项」会改到看不见的任务。
        manager.hideSecond = true
        dialog.refresh(false)
        compare(dialog.selectedIds.length, 1)
        compare(dialog.selectedIds[0], 1)
    }

    function test_overdueSelectionFollowsServiceDefinition() {
        dialog.selectOverdue()
        compare(dialog.selectedIds.length, 1)
        compare(dialog.selectedIds[0], 1)
    }

    function test_pendingDeletionAndNewSearchClearSelection() {
        dialog.pendingDeleteTaskId = 1
        compare(dialog.rows.length, 1)
        compare(dialog.rows[0].id, 2)
        dialog.toggle(2, true)
        dialog.refresh(true)
        compare(dialog.selectedIds.length, 0)
        // 待撤销删除的任务也不能留在选择里。
        dialog.toggle(1, true)
        dialog.refresh(false)
        compare(dialog.selectedIds.length, 0)
    }

    function test_unrelatedCompletionFailureDoesNotEnterDialog_data() {
        // 产品保证：任务工具不会接收别处的三类完成失败。
        return [ { tag: "complete", message: "完成失败：任务不存在" },
                 { tag: "uncomplete", message: "取消完成失败：数据库未打开" },
                 { tag: "note", message: "完成并记笔记失败：笔记超长" } ]
    }

    function test_unrelatedCompletionFailureDoesNotEnterDialog(data) {
        // 产品保证：工具弹窗开着时，别处完成失败不覆盖本弹窗的操作结果，自己的其它错误仍可显示。
        verify(dialog.opened)
        dialog.message = "原来的改期结果"
        manager.operationFailed(data.message)
        compare(dialog.message, "原来的改期结果")
        manager.operationFailed("任务搜索失败")
        compare(dialog.message, "任务搜索失败")
    }
}
