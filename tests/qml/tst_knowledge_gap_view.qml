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
    // 非空时 listGaps 只返回它。用来验证重查之后拿到的是新事实，
    // 而不只是「重查被调用过」——后者用固定数据集根本看不出区别。
    property var overrideRows: []
    // 置真时下一次 listGaps 会「同步」发一次失败再返回空列表。真实服务就是在调用过程中
    // 同步发 operationFailed 的——异步发根本暴露不出这个 bug。
    property bool failNextList: false

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
        id: fakeTaskManager

        // 任务变化只走信号：页面收到之后必须自己重查，不能等切页。
        signal tasksChanged()
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
            if (testCase.failNextList) {
                testCase.failNextList = false
                fakeGapService.operationFailed("读取知识缺口失败")
                return []
            }
            if (testCase.overrideRows.length > 0) {
                return testCase.overrideRows
            }
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
            taskManagerRef: fakeTaskManager
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
        testCase.overrideRows = []
        testCase.failNextList = false
        fakeSettings.dayStartHour = 4
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

    function test_defaultFilterReachesEveryActionableGroup() {
        var view = createView()
        // 服务端只要填了到期日就把状态推到「已安排」，所以按「待处理」(0) 筛选时，
        // 逾期 / 今天 / 之后 三个分组永远是空的：今日页提示条说有几条到期、
        // 点「去看看」却一条都看不到，就是这么来的。默认口径必须是「未解决」。
        compare(view.statusFilter, -2)
        compare(testCase.lastStatusFilter, -2)

        compare(view.gapsInGroup("overdue").length, 1)
        compare(view.gapsInGroup("today").length, 2)
        compare(view.gapsInGroup("future").length, 1)
        compare(view.gapsInGroup("unscheduled").length, 1)
        // 已解决的条目被筛掉，不占「未解决」这一页。
        compare(view.gapsInGroup("resolved").length, 0)
    }

    function test_resolvedSegmentSwitchesFilter() {
        var view = createView()
        var statusSwitch = findChild(view, "knowledgeGapStatusSwitch")
        verify(statusSwitch)
        compare(statusSwitch.currentIndex, 0)

        statusSwitch.activated(1)
        compare(view.statusFilter, 2)
        compare(testCase.lastStatusFilter, 2)
        compare(statusSwitch.currentIndex, 1)
        compare(view.gapsInGroup("resolved").length, 1)

        // 切回来必须回到「未解决」这个合并口径，不能落回某个具体状态。
        statusSwitch.activated(0)
        compare(view.statusFilter, -2)
        compare(testCase.lastStatusFilter, -2)
        compare(statusSwitch.currentIndex, 0)
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
        compare(hint.text, "关联任务已完成")
    }

    function test_convertIsDisabledWhileLinkedTaskIsOpen() {
        var view = createView()
        var arranged = Object.assign({}, testCase.allGaps[0],
                                     { id: 7, title: "已经转成任务", linkedTaskId: 70, linkedTaskOpen: true })
        view.gaps = [arranged]
        // 这条已经有一条没做完的任务。服务端会拒绝再转，按钮就不该摆出一个注定失败的动作。
        var button = findChild(view, "knowledgeGapConvertButton-7")
        verify(button)
        compare(button.enabled, false)
        var hint = findChild(view, "knowledgeGapLinkedTaskHint-7")
        verify(hint)
        compare(hint.text, "已转成任务")
    }

    function test_convertStaysEnabledOnceLinkedTaskIsDone() {
        var view = createView()
        view.gaps = [testCase.allGaps[5]]
        // 任务做完但还没想明白，允许再排一次。
        compare(findChild(view, "knowledgeGapConvertButton-6").enabled, true)
    }

    function test_dayStartHourZeroIsNotReplacedByDefault() {
        fakeSettings.dayStartHour = 0
        var view = createView()
        // 0 点日界是合法设置。写成 dayStartHour || 4 会把它当成缺值改回 4，
        // 凌晨 0–4 点「今天做」就会把任务排到前一天，和服务端的提醒口径分家。
        compare(view.dayStartHour(), 0)
    }

    function test_operationFailureSurfacesAndReloadClearsIt() {
        var view = createView()
        fakeGapService.operationFailed("写入失败")
        compare(view.loadError, "写入失败")
        // 只有服务确认数据已经变了才清错，不能靠任意界面操作掩盖失败。
        fakeGapService.gapsChanged()
        compare(view.loadError, "")
    }

    function test_taskChangeRefreshesLinkedTaskState() {
        var linkedOpen = Object.assign({}, testCase.allGaps[0],
                                       { id: 7, title: "已经转成任务", linkedTaskId: 70,
                                         linkedTaskOpen: true })
        testCase.overrideRows = [linkedOpen]
        var view = createView()

        var button = null
        tryVerify(function () {
            button = findChild(view, "knowledgeGapConvertButton-7")
            return button !== null
        })
        compare(button.enabled, false)

        // 关联任务被删掉（撤销窗口结束、删除真正提交）或者被后台专注自动完成之后，
        // 库里的关联已经没了。这两件事都发生在别的页面，缺口服务也不会因此发 gapsChanged，
        // 本页只能靠任务信号知道。收不到就一直显示「已转成任务」、按钮一直点不了，
        // 直到用户切一次页面才恢复。
        testCase.overrideRows = [Object.assign({}, linkedOpen,
                                               { linkedTaskId: 0, linkedTaskOpen: false })]
        var before = testCase.listCalls
        fakeTaskManager.tasksChanged()
        tryVerify(function () { return testCase.listCalls > before })
        // 重新查找而不是复用上面那个引用：重查会重建委托。
        tryVerify(function () {
            var refreshed = findChild(view, "knowledgeGapConvertButton-7")
            return refreshed !== null && refreshed.enabled
        })
    }

    function test_inactivePageIgnoresFailuresRaisedElsewhere() {
        var view = createTemporaryObject(viewComponent, testCase, { pageActive: false })
        verify(view)
        // 今日页轮询提醒摘要失败（自动备份 VACUUM INTO 期间 database is locked）时，
        // 今日页自己吞掉了，但信号是服务发的，而缺口页从启动起就一直存在。
        // 没有门禁就会在这里攒下一条红条，用户某次切过来才看到，且与当时操作无关。
        fakeGapService.operationFailed("读取待补提醒失败")
        compare(view.loadError, "")
    }

    function test_reloadClearsStaleErrorOnSuccess() {
        var view = createView()
        fakeGapService.operationFailed("写入失败")
        compare(view.loadError, "写入失败")
        // 换筛选、改搜索词、重新进页面都会走 reload()。查询成功就说明页面内容是新的，
        // 描述旧失败的红条不能继续挂着——它还会把空状态压掉。
        view.reload()
        compare(view.loadError, "")
    }

    function test_activationFailureShowsErrorInsteadOfEmptyState() {
        var view = createTemporaryObject(viewComponent, testCase, { pageActive: false })
        verify(view)

        testCase.failNextList = true
        view.pageActive = true
        // 切进来的第一次查询失败必须变成一条错误，而不是「没有条目」。
        // 门禁写成 enabled 绑定时，pageActive 刚变 true 的那一次同步查询里绑定还没重算，
        // 失败信号会被整个丢掉——用户看到的是一个若无其事的空页面。
        compare(view.loadError, "读取知识缺口失败")
        compare(view.gaps.length, 0)
    }

    function test_missingServiceLeavesEmptyListInsteadOfThrowing() {
        var view = createTemporaryObject(viewComponent, testCase, { knowledgeGapServiceRef: null })
        verify(view)
        view.reload()
        compare(view.gaps.length, 0)
    }
}
