import QtQuick
import QtTest
import "../../qml/views"
import "../../qml/components"
import "../../qml"

// 切进页面的那一次查询失败，必须变成可见的错误，不能被显示成空页面（2026-09-15 审查修复）。
//
// 常驻页面（StackLayout 的子页）用 pageActive 给失败信号做门禁，曾写成
// `Connections { enabled: root.pageActive }`。enabled 是绑定，重算晚于 onPageActiveChanged：
// 页面在处理函数里同步查询，服务又是在这次调用过程中同步发 operationFailed 的——
// 那一刻绑定还是旧值 false，信号被整个丢掉。KnowledgeGapView 在 81bdb74 修过，
// 另外几页原样保留：当时的目标页（2026-09 已删除）因此显示「没有进行中的目标」并引导重复新建。
//
// 替身一律在查询函数「内部」同步发失败；改成异步发就暴露不出这个问题。
// 断言用替身给出的原文：页面对替身缺方法抛出的异常会兜成通用文案，只断言「非空」会误判通过。
TestCase {
    id: testCase
    name: "EntityWriteFailureFeedback"
    visible: true
    property var seedRows: []
    when: windowShown
    width: 1100
    height: 760

    property var fixedNow: new Date(2026, 6, 15, 12, 0, 0)

    QtObject {
        id: taskManager

        signal tasksChanged()
        signal operationFailed(string message)

        property bool failTodayTasks: false
        property bool failOverdue: false
        property bool failWeekTasks: false

        function getTodayTasks() {
            if (failTodayTasks) {
                operationFailed("今日任务查询失败")
                return []
            }
            return testCase.seedRows
        }
        function getOverdueUncompletedTasks() {
            if (failOverdue) {
                operationFailed("逾期任务查询失败")
                return []
            }
            return []
        }
        function getWeekTasks(weekStartIso) {
            if (failWeekTasks) {
                operationFailed("本周任务查询失败")
                return []
            }
            return testCase.seedRows
        }
        function getTasksByDate(date) { return [] }
        function getMonthTasks(year, month) { return [] }
        function moveTasksToToday(ids) { return true }
        function addTask(title, date, categoryId) { operationFailed("新建任务失败：T32 写入被拒绝"); return false }
        function updateTaskChanges(id, changes) { operationFailed("修改任务失败：T32 写入被拒绝"); return false }
        function moveTaskToDate(id, date) { operationFailed("任务改期失败：T32 写入被拒绝"); return false }
        function setTaskCompleted(id, completed) { return true }
        function deleteTask(id) { return true }
        function updateTask(id, title, categoryId, date) { return true }
        function isRoutineGeneratedTask(id) { return false }
    }

    QtObject {
        id: statisticsService

        signal operationFailed(string message)

        property bool failStats: false

        function getTodayStats() {
            if (failStats) {
                operationFailed("统计查询失败")
            }
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0,
                     sessionCount: 0, pomodoroCount: 0 }
        }
        function getStreakDays() { return 0 }
        function getTotalFocusDuration() { return 0 }
        function getTodayTaskStats() { return { tasks: [], totalDuration: 0, taskCount: 0 } }
        function getDayStats(day) {
            if (failStats) {
                operationFailed("统计查询失败")
            }
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0,
                     sessionCount: 0 }
        }
        function getDayComparison(day) { return {} }
        function getWeekStats(start) { return [] }
        // 复盘接口是统计页契约的一部分，替身必须提供；这里返回没有可展示内容的成功结果。
        function getWeeklyReview(weekStart, logicalTodayIso) {
            return { loadState: "ready", periodState: "current", hasData: false, hasDisplayContent: false,
                     goal: ({}), todayGoal: ({}), subjects: [], plannedTasks: ({}), facts: [] }
        }
        function getCategoryStats(startIso, endIso) { return { categories: [], totalDuration: 0 } }
    }

    QtObject {
        id: routineManager

        signal routinesChanged()
        signal operationFailed(string message)

        property bool failMaterialize: false
        property bool failLoad: false
        property bool failReadAfterActive: false

        function getRoutines() { if (failLoad) { operationFailed("每日例行读取失败：T32 后续读取失败"); return [] }; return [{id:7,title:"例行",categoryId:-1,active:true,weekdays:127}] }
        function addRoutine(title, category) { operationFailed("新增例行失败：T32 写入被拒绝"); return false }
        function updateRoutineChanges(id, changes) { operationFailed("修改例行失败：T32 写入被拒绝"); return false }
        function deleteRoutine(id) { operationFailed("删除例行失败：T32 写入被拒绝"); return false }
        function setRoutineActive(id, active) { if (failReadAfterActive) failLoad = true; operationFailed("停用例行失败：T32 写入被拒绝"); return false }
        function setRoutineWeekdays(id, mask) { operationFailed("修改例行重复日失败：T32 写入被拒绝"); return false }
        function materializeToday() {
            if (failMaterialize) {
                operationFailed("每日例行生成失败：数据库被锁")
            }
        }
    }

    QtObject {
        id: gapService

        signal gapsChanged()
        signal operationFailed(string message)

        function getReminderSummary() { return ({}) }
        function listGaps(statusFilter, categoryId, searchText, limit) { return [] }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged()
        signal operationFailed(string message)
        function addCategory(name, color) { operationFailed("新增科目失败：T32 写入被拒绝"); return -1 }
        function updateCategory(id, name, color) { operationFailed("修改科目失败：T32 写入被拒绝"); return false }
        function deleteCategory(id) { operationFailed("删除科目失败：T32 写入被拒绝"); return false }
        property bool failDeleteCheck: false
        function canDeleteCategory(id) {
            if (failDeleteCheck) { operationFailed("科目加载失败：T32 数据库未打开"); return false }
            return true
        }

        function readAllCategories() { return { ok: true, categories: getAllCategories() } }
        function getAllCategories() { return [] }
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)
        signal restCompleted(int duration)

        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int elapsedSeconds: 0
        property int remainingSeconds: 0
        property int targetSeconds: 0
        property int mode: 0
        property int phase: 0
        property string sessionLogicalDate: ""
    }

    QtObject {
        id: settings

        signal dailyFocusGoalChanged()

        property int dayStartHour: 4
        property bool reduceMotion: true
        property bool dashboardTimerVisible: true
        property int workMinutes: 25
        property int breakMinutes: 5
        property int lastMode: 0
        property string nickname: ""
        property string rolloverIgnoredDate: ""
        property string semesterStartDate: ""
        property int semesterWeeks: 16
        property string scheduleDisplayMode: "time"
        property bool scheduleShowWeekend: true

        function dailyFocusGoalMinutesForDate(isoDate) { return 0 }
    }

    Component {
        id: dashboardComponent

        DashboardView {
            width: 1000
            height: 680
            pageActive: false
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            categoryManagerRef: categoryManager
            settingsRef: settings
            nowProvider: function() { return testCase.fixedNow }
        }
    }

    Component {
        id: weekComponent

        WeekPlanView {
            width: 1000
            height: 700
            pageActive: false
            taskManagerRef: taskManager
            logicalDayServiceRef: logicalDayService
            settingsRef: settings
            categoryManagerRef: categoryManager
            logicalNowProvider: function() { return testCase.fixedNow }
        }
    }

    Component {
        id: todayComponent

        TodayTaskView {
            width: 860
            height: 620
            pageActive: false
            taskManagerRef: taskManager
            statisticsServiceRef: statisticsService
            routineManagerRef: routineManager
            focusTimerRef: focusTimer
            logicalDayServiceRef: logicalDayService
            categoryManagerRef: categoryManager
            knowledgeGapServiceRef: gapService
            settingsRef: settings
        }
    }

    Component { id: categoryComponent; CategoryDialog { manager: categoryManager } }
    Component { id: routineComponent; RoutineDialog { routineManagerRef: routineManager; categoryManagerRef: categoryManager } }
    Component { id: addComponent; AddTaskDialog { categoryManagerRef: categoryManager; taskSubmitter: function() { return taskManager.addTask() } } }
    Component { id: editComponent; EditTaskDialog { categoryManagerRef: categoryManager; taskSubmitter: function(id, changes) { return taskManager.updateTaskChanges(id, changes) } } }
    Component { id: promptComponent; NewCategoryPrompt { categoryManagerRef: categoryManager } }
    Component { id: toolsComponent; TaskToolsDialog { taskManagerRef: taskManager; categoryManagerRef: categoryManager } }

    function init() { seedRows = []; routineManager.failLoad = false; routineManager.failReadAfterActive = false; categoryManager.failDeleteCheck = false }
    function openDialog(component) {
        var dialog = createTemporaryObject(component, testCase)
        verify(dialog)
        dialog.open()
        tryCompare(dialog, "opened", true)
        return dialog
    }
    function task() { return {id:42,title:"原任务",date:new Date(2026,6,15),categoryId:-1,estimatedMinutes:0,notes:"",completed:false} }
    // 产品保证：科目操作只在发起弹窗原有位置显示一次具体原因，旁观弹窗和关闭后的弹窗不受污染。
    function test_categoryFailures_data() { return [{tag:"add"},{tag:"update"},{tag:"delete"}] }
    // 产品保证：科目拒绝不会把具体原因改成重名猜测，失败后保留用户输入。
    function test_categoryFailures(data) {
        var dialog = openDialog(categoryComponent)
        var observer = openDialog(editComponent)
        if (data.tag === "add") {
            dialog.beginAdd(); findChild(dialog,"categoryNameInput").text="新科目"
        } else dialog.beginEdit({id:7,name:"原科目",color:"#123456"})
        observer.errorText = "原消息"
        if (data.tag === "add") dialog.addCategory()
        else if (data.tag === "update") dialog.updateCategory()
        else {
            dialog.deleteCategory(7)
            tryCompare(findChild(dialog,"categoryDeleteConfirmation"),"opened",true)
            dialog.commitCategoryDeletion(7)
        }
        var action = data.tag === "add" ? "新增科目" : data.tag === "update" ? "修改科目" : "删除科目"
        compare(dialog.errorText, action + "失败：T32 写入被拒绝")
        compare(observer.errorText, "原消息")
        var mainError=findChild(dialog,"categoryListError"), editError=findChild(dialog,"categoryEditorError"), deleteError=findChild(dialog,"categoryDeletionError")
        verify(mainError && editError && deleteError)
        compare(mainError.visible,false)
        compare(editError.visible,data.tag !== "delete")
        compare(deleteError.visible,data.tag === "delete")
        var confirmation=findChild(dialog,"categoryDeleteConfirmation")
        confirmation.close()
        dialog.close(); tryCompare(dialog, "visible", false)
        dialog.errorText = "关闭前的结果"
        categoryManager.operationFailed("新增科目失败：别处失败")
        compare(dialog.errorText, "关闭前的结果")
    }
    // 产品保证：下拉内联新建科目的失败只留在内联提示框，宿主任务弹窗不多显示一次。
    function test_inlineCategoryFailureStaysInPrompt() {
        var host = openDialog(addComponent)
        var prompt = findChild(host, "addTaskNewCategoryPrompt")
        verify(prompt); prompt.openPrompt(); tryCompare(prompt, "opened", true)
        findChild(prompt,"newCategoryPromptField").text = "新科目"
        prompt.submit()
        compare(prompt.errorText, "新增科目失败：T32 写入被拒绝")
        compare(findChild(host,"addTaskErrorLabel").text, "")
        compare(findChild(prompt,"newCategoryPromptField").text, "新科目")
    }
    // 产品保证：例行五种写入拒绝各显示原文，重复日弹窗独占自己的失败，页面不显示第二条。
    function test_routineFailures_data() { return [{tag:"add"},{tag:"update"},{tag:"delete"},{tag:"active"},{tag:"weekdays"}] }
    // 产品保证：例行父弹窗、重复日弹窗和页面不会同时显示同一次写入失败。
    function test_routineFailures(data) {
        var page = createTemporaryObject(todayComponent, testCase)
        verify(page); page.pageActive = true; page.loadError = ""
        var dialog = openDialog(routineComponent)
        var item = {id:7,title:"原例行",categoryId:-1,weekdays:127}
        var action = ""
        if (data.tag === "add") { findChild(dialog,"routineTitleField").text="新例行"; dialog.submit(); action="新增例行" }
        else if (data.tag === "update") { dialog.beginEditing(item); findChild(dialog,"routineTitleField").text="修改后"; dialog.submit(); action="修改例行" }
        else if (data.tag === "delete") {
            dialog.deleteRoutine(7); tryCompare(dialog.deleteConfirmationRef,"opened",true)
            dialog.commitRoutineDeletion(7); action="删除例行"
        }
        else if (data.tag === "active") { dialog.setRoutineActive(7,false); action="停用例行" }
        else {
            dialog.editWeekdays(item)
            var weekdays = dialog.weekdayDialogRef
            tryCompare(weekdays,"opened",true); weekdays.save(); action="修改例行重复日"
            compare(weekdays.errorText,action + "失败：T32 写入被拒绝")
            compare(dialog.errorText,"")
        }
        if (data.tag !== "weekdays") compare(dialog.errorText,action+"失败：T32 写入被拒绝")
        compare(page.loadError, "")
        var formError=findChild(dialog,"routineFormError"), deleteError=findChild(dialog,"routineDeletionError")
        verify(formError && deleteError)
        compare(formError.visible,data.tag !== "weekdays" && data.tag !== "delete")
        compare(deleteError.visible,data.tag === "delete")
        dialog.close(); tryCompare(dialog,"visible",false); dialog.errorText="关闭前结果"
        routineManager.operationFailed("新增例行失败：别处")
        compare(dialog.errorText,"关闭前结果")
    }
    // 产品保证：任务表单只显示当前调用的具体原因，不接收别处任务或科目写入的失败。
    function test_taskForms_data() { return [{tag:"add"},{tag:"edit"}] }
    // 产品保证：表单失败保留输入，具体原因不会在返回 false 后被通用文案覆盖。
    function test_taskForms(data) {
        var dialog = openDialog(data.tag === "add" ? addComponent : editComponent)
        // 修复前组件没有服务引用；让红测落在原因断言而非不存在的属性上。
        if ("taskManagerRef" in dialog) dialog.taskManagerRef = taskManager
        if (data.tag === "edit") dialog.openForTask(task())
        var field = findChild(dialog,data.tag === "add" ? "titleField" : "editTitleField")
        field.text="修改后的标题"
        dialog.submit()
        var expected=(data.tag === "add" ? "新建任务" : "修改任务") + "失败：T32 写入被拒绝"
        compare(data.tag === "add" ? findChild(dialog,"addTaskErrorLabel").text : dialog.errorText,expected)
        compare(field.text,"修改后的标题")
        taskManager.operationFailed("修改任务失败：别处")
        categoryManager.operationFailed("新增科目失败：别处")
        compare(data.tag === "add" ? findChild(dialog,"addTaskErrorLabel").text : dialog.errorText,expected)
    }
    // 产品保证：三个任务页面的编辑弹窗独占失败，行内改名仍在页面原错误条显示一次具体原因。
    function test_pageTaskFailures_data() { return [{tag:"today",component:todayComponent},{tag:"week",component:weekComponent},{tag:"dashboard",component:dashboardComponent}] }
    // 产品保证：新增信号不会同时污染页面与编辑弹窗，行内失败也不丢失原文。
    function test_pageTaskFailures(data) {
        seedRows=[task()]
        var page=createTemporaryObject(data.component,testCase)
        verify(page); page.pageActive=true
        tryVerify(function(){ return findChild(page,"taskTitleEditField") !== null })
        var field=findChild(page,"taskTitleEditField"), row=field.parent
        while (row && !("renameSubmitter" in row)) row=row.parent
        verify(row); page.loadError="旧错误"
        compare(row.renameSubmitter(42,"行内修改"),false)
        compare(page.loadError,"修改任务失败：T32 写入被拒绝")
        // 通过任务行的真实编辑动作打开宿主实例，验证生产接线而非另造表单。
        row.editClicked(42)
        var name=data.tag === "today" ? "todayEditTaskDialog" : data.tag === "week" ? "weekEditTaskDialog" : "dashboardEditTaskDialog"
        var popup=findChild(page,name)
        verify(popup); tryCompare(popup,"opened",true)
        var editor=findChild(popup,"editTitleField")
        verify(editor)
        page.loadError=""; editor.text="表单修改"; popup.submit()
        compare(popup.errorText,"修改任务失败：T32 写入被拒绝")
        compare(page.loadError,"")
    }
    // 产品保证：周计划拖动改期失败继续在页面错误条显示具体原因，不报成加载故障或成功。
    function test_weekDragKeepsReason() {
        var page=createTemporaryObject(weekComponent,testCase)
        verify(page); page.pageActive=true; page.dropTargetIndex=2
        page.loadError="旧错误"; page.commitDrag(42,false)
        compare(page.loadError,"任务改期失败：T32 写入被拒绝")
    }
    // 产品保证：任务工具不会把别处的单条写入失败显示成搜索或批量操作失败。
    function test_toolsIgnoreUnrelatedWrites() {
        var dialog=openDialog(toolsComponent)
        dialog.message="自己的结果"
        taskManager.operationFailed("新建任务失败：别处")
        taskManager.operationFailed("修改任务失败：别处")
        taskManager.operationFailed("任务改期失败：别处")
        compare(dialog.message,"自己的结果")
    }
    // 产品保证：今日与周计划的新建失败只出现在原新建弹窗，不叠加页面错误条。
    function test_pageCreateFailures_data() { return [{tag:"today",component:todayComponent},{tag:"week",component:weekComponent}] }
    // 产品保证：页面真实装配把新建原因原样交给弹窗，失败保留草稿。
    function test_pageCreateFailures(data) {
        var page=createTemporaryObject(data.component,testCase)
        verify(page); page.pageActive=true
        var dialog=findChild(page,data.tag === "today" ? "todayAddTaskDialog" : "weekAddTaskDialog")
        verify(dialog); dialog.open(); tryCompare(dialog,"opened",true)
        page.loadError=""; findChild(dialog,"titleField").text="新任务"
        dialog.submit()
        compare(findChild(dialog,"addTaskErrorLabel").text,"新建任务失败：T32 写入被拒绝")
        compare(page.loadError,"")
    }
    // 产品保证：任务工具内的编辑失败只在编辑子弹窗显示，工具结果区保持原内容。
    function test_toolsEditorOwnsItsFailure() {
        var tools=openDialog(toolsComponent)
        var editor=findChild(tools,"toolsEditTaskDialog")
        verify(editor); editor.openForTask(task()); tryCompare(editor,"opened",true)
        tools.message="原结果"; findChild(editor,"editTitleField").text="修改标题"
        editor.submit()
        compare(editor.errorText,"修改任务失败：T32 写入被拒绝")
        compare(tools.message,"原结果")
    }
    // 产品保证：状态写入失败后的列表重读不能覆盖最初的具体操作原因。
    function test_activeFailureKeepsReasonWhenRefreshAlsoFails() {
        var dialog=openDialog(routineComponent)
        routineManager.failReadAfterActive=true
        dialog.setRoutineActive(7,false)
        compare(dialog.errorText,"停用例行失败：T32 写入被拒绝")
    }
    // 产品保证：科目删除前检查失败时保留存储原因，不把读库失败误报成禁止删除。
    function test_categoryDeleteCheckPreservesStorageReason() {
        var dialog=openDialog(categoryComponent)
        categoryManager.failDeleteCheck=true
        dialog.commitCategoryDeletion(7)
        compare(dialog.errorText,"科目加载失败：T32 数据库未打开")
    }
    // 产品保证：任务工具或其它宿主的表单写入失败不会在底层活跃页面再显示一次。
    function test_pageIgnoresOtherFormFailures_data() {
        return [{tag:"today-add",component:todayComponent,add:true},{tag:"today-edit",component:todayComponent,add:false},
                {tag:"week-add",component:weekComponent,add:true},{tag:"week-edit",component:weekComponent,add:false},
                {tag:"dashboard-add",component:dashboardComponent,add:true},{tag:"dashboard-edit",component:dashboardComponent,add:false}]
    }
    // 产品保证：页面过滤依据失败的发起方式，不能只认自己直属的编辑弹窗。
    function test_pageIgnoresOtherFormFailures(data) {
        var page=createTemporaryObject(data.component,testCase)
        verify(page); page.pageActive=true
        var dialog=openDialog(data.add ? addComponent : editComponent)
        if ("taskManagerRef" in dialog) dialog.taskManagerRef=taskManager
        if (!data.add) dialog.openForTask(task())
        findChild(dialog,data.add ? "titleField" : "editTitleField").text="别处的表单修改"
        page.loadError=""; dialog.submit()
        compare(data.add ? findChild(dialog,"addTaskErrorLabel").text : dialog.errorText,
                (data.add ? "新建任务" : "修改任务") + "失败：T32 写入被拒绝")
        compare(page.loadError,"")
    }

    // 产品保证：单条待删失败由标题提示负责，三页和任务工具不重复显示，但批量删除原因仍显示。
    function test_pendingDeletionPrefixIsNotABatchFailure_data() {
        return [{tag:"today",component:todayComponent},{tag:"week",component:weekComponent},
                {tag:"dashboard",component:dashboardComponent},{tag:"tools",component:toolsComponent}]
    }
    // 产品保证：只过滤新单条删除前缀，不误吞原来的批量删除失败。
    function test_pendingDeletionPrefixIsNotABatchFailure(data) {
        var item = data.tag === "tools" ? openDialog(data.component) : createTemporaryObject(data.component,testCase)
        verify(item)
        if (data.tag !== "tools") item.pageActive = true
        var key = data.tag === "tools" ? "message" : "loadError"
        item[key] = "原结果"
        taskManager.operationFailed("删除任务失败：T33-2 pending blocked")
        compare(item[key],"原结果")
        taskManager.operationFailed("删除失败：T33-2 batch blocked")
        compare(item[key],"删除失败：T33-2 batch blocked")
    }

}
