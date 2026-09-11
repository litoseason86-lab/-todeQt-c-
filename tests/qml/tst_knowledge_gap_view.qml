import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"
import "../../qml/views"

// 清单页的验收重点：分组完全跟随服务给出的事实、状态筛选真的重查、
// 删除必须经过二次确认，以及「关联任务已完成」只提示不自动解决。
TestCase {
    id: testCase
    name: "KnowledgeGapView"
    when: windowShown
    width: 900
    height: 700

    property int listCalls: 0
    property int lastStatusFilter: -99
    property string lastSearchText: ""
    property int convertCalls: 0
    property int lastConvertId: -1
    property int resolveCalls: 0
    property int reopenCalls: 0
    property int deleteCalls: 0
    property int lastDeleteId: -1
    property int convertedSignals: 0

    // 固定数据集：逾期、今天、之后、未排期、已解决各一条，正好盖满五个分组。
    // overdue / dueToday / scheduled 都由服务算好，页面不许自己比日期。
    readonly property var allGaps: [
        { id: 1, title: "逾期那条", detail: "", categoryId: 0, categoryName: "", categoryColor: "",
          sourceTaskId: 0, sourceTaskTitle: "", priority: 1, status: 1, dueDate: "2026-09-01",
          scheduled: true, overdue: true, overdueDays: 10, dueToday: false, resolution: "",
          linkedTaskId: 0, linkedTaskCompleted: false, linkedTaskTitle: "" },
        { id: 2, title: "今天那条", detail: "", categoryId: 0, categoryName: "", categoryColor: "",
          sourceTaskId: 0, sourceTaskTitle: "", priority: 1, status: 1, dueDate: "2026-09-11",
          scheduled: true, overdue: false, overdueDays: 0, dueToday: true, resolution: "",
          linkedTaskId: 0, linkedTaskCompleted: false, linkedTaskTitle: "" },
        { id: 3, title: "以后那条", detail: "", categoryId: 0, categoryName: "", categoryColor: "",
          sourceTaskId: 0, sourceTaskTitle: "", priority: 1, status: 1, dueDate: "2026-09-20",
          scheduled: true, overdue: false, overdueDays: 0, dueToday: false, resolution: "",
          linkedTaskId: 0, linkedTaskCompleted: false, linkedTaskTitle: "" },
        { id: 4, title: "未排期那条", detail: "", categoryId: 0, categoryName: "", categoryColor: "",
          sourceTaskId: 0, sourceTaskTitle: "", priority: 2, status: 0, dueDate: "",
          scheduled: false, overdue: false, overdueDays: 0, dueToday: false, resolution: "",
          linkedTaskId: 0, linkedTaskCompleted: false, linkedTaskTitle: "" },
        { id: 5, title: "已解决那条", detail: "", categoryId: 0, categoryName: "", categoryColor: "",
          sourceTaskId: 0, sourceTaskTitle: "", priority: 1, status: 2, dueDate: "2026-09-05",
          scheduled: true, overdue: false, overdueDays: 0, dueToday: false, resolution: "想明白了",
          linkedTaskId: 9, linkedTaskCompleted: true, linkedTaskTitle: "做过的任务" },
        { id: 6, title: "任务做完但没想明白", detail: "", categoryId: 0, categoryName: "", categoryColor: "",
          sourceTaskId: 0, sourceTaskTitle: "", priority: 1, status: 1, dueDate: "2026-09-11",
          scheduled: true, overdue: false, overdueDays: 0, dueToday: true, resolution: "",
          linkedTaskId: 8, linkedTaskCompleted: true, linkedTaskTitle: "已完成的任务" }
    ]

    QtObject {
        id: fakeSettings

        // 不要再显式声明 dayStartHourChanged：property 自带同名变更信号，
        // 重复声明会直接编译失败。视图的 Connections 接的就是这个自动信号。
        property int dayStartHour: 4
    }

    QtObject {
        id: fakeCategoryManager

        function getAllCategories() {
            return [{ id: 1, name: "数学", color: "#ff8800" }]
        }
    }

    QtObject {
        id: fakeGapService

        property int maxTitleLength: 100

        signal gapsChanged()
        signal operationFailed(string message)

        function listGaps(statusFilter, categoryId, searchText, limit) {
            testCase.listCalls += 1
            testCase.lastStatusFilter = statusFilter
            testCase.lastSearchText = searchText
            var rows = []
            for (var i = 0; i < testCase.allGaps.length; ++i) {
                var gap = testCase.allGaps[i]
                if (statusFilter >= 0 && Number(gap.status) !== statusFilter) {
                    continue
                }
                if (statusFilter === -2 && Number(gap.status) === 2) {
                    continue
                }
                rows.push(gap)
            }
            return rows
        }

        function convertToTask(gapId, dateValue) {
            testCase.convertCalls += 1
            testCase.lastConvertId = gapId
            return 100 + gapId
        }

        function resolveGap(gapId, resolution) { testCase.resolveCalls += 1; return true }
        function reopenGap(gapId) { testCase.reopenCalls += 1; return true }
        function deleteGap(gapId) {
            testCase.deleteCalls += 1
            testCase.lastDeleteId = gapId
            return true
        }
    }

    Component {
        id: viewComponent

        KnowledgeGapView {
            width: 900
            height: 700
            knowledgeGapServiceRef: fakeGapService
            categoryManagerRef: fakeCategoryManager
            settingsRef: fakeSettings
            pageActive: true

            onGapConvertedToTask: function (title) { testCase.convertedSignals += 1 }
        }
    }

    function createView() {
        var view = createTemporaryObject(viewComponent, testCase)
        verify(view)
        return view
    }

    function findChild(root, name) {
        if (root.objectName === name) {
            return root
        }
        for (var i = 0; i < root.children.length; ++i) {
            var found = findChild(root.children[i], name)
            if (found) {
                return found
            }
        }
        return null
    }

    function init() {
        testCase.listCalls = 0
        testCase.lastStatusFilter = -99
        testCase.lastSearchText = ""
        testCase.convertCalls = 0
        testCase.lastConvertId = -1
        testCase.resolveCalls = 0
        testCase.reopenCalls = 0
        testCase.deleteCalls = 0
        testCase.lastDeleteId = -1
        testCase.convertedSignals = 0
    }

    function test_groupsFollowServiceFacts() {
        var view = createView()
        // 分组只看服务给的 overdue / dueToday / scheduled，页面不自己比日期：
        // 「今天」的口径只能有一份，在 C++ 侧。
        view.gaps = testCase.allGaps

        compare(view.gapsInGroup("overdue").length, 1)
        compare(view.gapsInGroup("overdue")[0].title, "逾期那条")
        compare(view.gapsInGroup("today").length, 2)
        compare(view.gapsInGroup("future").length, 1)
        compare(view.gapsInGroup("unscheduled").length, 1)
        compare(view.gapsInGroup("resolved").length, 1)
        compare(view.gapsInGroup("resolved")[0].title, "已解决那条")
    }

    function test_resolvedGapNeverLandsInOverdueGroup() {
        var view = createView()
        // 已解决的那条 dueDate 在过去。它不该再被归进逾期——
        // 它已经不需要任何人停下来处理了。
        view.gaps = [testCase.allGaps[4]]
        compare(view.gapsInGroup("overdue").length, 0)
        compare(view.gapsInGroup("resolved").length, 1)
    }

    function test_metaTextReportsOverdueDays() {
        var view = createView()
        // 只报「还有几条」没有推力，拖了多少天才有。
        var text = view.metaTextFor(testCase.allGaps[0])
        verify(text.indexOf("已逾期 10 天") >= 0)
        compare(view.metaTextFor(testCase.allGaps[1]).indexOf("今天到期") >= 0, true)
        compare(view.metaTextFor(testCase.allGaps[3]).indexOf("未排期") >= 0, true)
    }

    function test_statusFilterTriggersReload() {
        var view = createView()
        var before = testCase.listCalls

        view.statusFilter = 2
        view.reload()
        compare(testCase.listCalls, before + 1)
        compare(testCase.lastStatusFilter, 2)
        compare(view.gaps.length, 1)
        compare(view.gaps[0].title, "已解决那条")
    }

    function test_searchTextIsPassedThrough() {
        var view = createView()
        view.searchText = "对角化"
        view.reload()
        compare(testCase.lastSearchText, "对角化")
    }

    function test_convertToTaskEmitsSignalWithTitle() {
        var view = createView()
        view.convertToTask(testCase.allGaps[0])
        compare(testCase.convertCalls, 1)
        compare(testCase.lastConvertId, 1)
        compare(testCase.convertedSignals, 1)
    }

    function test_resolveAndReopenGoThroughService() {
        var view = createView()
        view.resolveGap(testCase.allGaps[1])
        compare(testCase.resolveCalls, 1)
        view.reopenGap(testCase.allGaps[4])
        compare(testCase.reopenCalls, 1)
    }

    function test_deleteRequiresConfirmation() {
        var view = createView()
        view.requestDelete(testCase.allGaps[3])
        // 请求删除本身不能直接落库：删除走二次确认，不走撤销窗口。
        compare(testCase.deleteCalls, 0)
        compare(view.pendingDeleteGapId, 4)
        compare(view.pendingDeleteTitle, "未排期那条")

        view.confirmPendingDelete()
        compare(testCase.deleteCalls, 1)
        compare(testCase.lastDeleteId, 4)
        // 确认之后待删状态要清空，否则连点两次会重复提交同一条。
        compare(view.pendingDeleteGapId, -1)
    }

    function test_deleteCanBeCancelled() {
        var view = createView()
        view.requestDelete(testCase.allGaps[3])
        view.cancelPendingDelete()
        compare(testCase.deleteCalls, 0)
        compare(view.pendingDeleteGapId, -1)
    }

    function test_confirmWithoutPendingItemDeletesNothing() {
        var view = createView()
        // 没有待删项时确认必须是空操作，不能拿上一次的编号去删。
        view.confirmPendingDelete()
        compare(testCase.deleteCalls, 0)
    }

    function test_completedLinkedTaskDoesNotAutoResolve() {
        var view = createView()
        view.gaps = [testCase.allGaps[5]]
        // 做完关联任务完全可能还是没搞懂，所以这条仍在「今天」组里等人处理，
        // 页面只给一行提示，绝不替用户标记已解决。
        compare(view.gapsInGroup("resolved").length, 0)
        compare(view.gapsInGroup("today").length, 1)
        compare(testCase.resolveCalls, 0)
        var hint = findChild(view, "knowledgeGapLinkedTaskHint-6")
        verify(hint)
    }

    function test_operationFailureSurfacesAndReloadClearsIt() {
        var view = createView()
        fakeGapService.operationFailed("写入失败")
        compare(view.loadError, "写入失败")
        // 只有服务确认数据已经变了才清错，不能靠任意界面操作掩盖失败。
        fakeGapService.gapsChanged()
        compare(view.loadError, "")
    }

    function test_missingServiceLeavesEmptyListInsteadOfThrowing() {
        var view = createTemporaryObject(viewComponent, testCase, { knowledgeGapServiceRef: null })
        verify(view)
        view.reload()
        compare(view.gaps.length, 0)
    }
}
