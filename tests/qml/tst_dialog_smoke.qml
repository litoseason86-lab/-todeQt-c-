import QtQuick
import QtTest
import "../../qml/components"

// 弹窗冒烟：把「从未被任何测试打开过」的弹窗真正打开一次。
//
// 为什么单独立一条：QML 运行时告警门禁（见 plans/044）只看得见测试实际实例化过的
// 组件，而弹窗的绑定在打开之前根本不求值——它们是那个门禁最大的盲区。
// 静态的 qmllint 也看不到，它不执行绑定。
//
// 断言刻意写得浅：这里不重复各弹窗自己的业务用例，只保证「打开得来、关得掉、
// 关键内容在」。真正的价值由 CMake 挂在每个 QML 测试上的 FAIL_REGULAR_EXPRESSION
// 提供——打开过程中任何 "Unable to assign / TypeError / Binding loop" 都会让这条转红。
//
// 替身刻意只给业务必需的字段，不求完整：本仓约定组件要扛得住「ref 存在但缺字段」
// （离屏走查与对比度审计都只注入自己关心的那几个），扛不住的正该在这里暴露。
TestCase {
    id: testCase
    name: "DialogSmoke"
    when: windowShown
    width: 900
    height: 700
    visible: true

    QtObject {
        id: scheduleService

        signal scheduleChanged()
        signal periodsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 60
        readonly property int maxLocationLength: 60
        readonly property int maxWeekIndex: 60
        readonly property int maxPeriodCount: 24
        property bool failPeriodLoad: false
        property int setPeriodsCallCount: 0
        property var currentPeriods: [
            { index: 1, startMinutes: 480, endMinutes: 525 },
            { index: 2, startMinutes: 535, endMinutes: 580 }
        ]

        function getPeriods() {
            if (scheduleService.failPeriodLoad) {
                scheduleService.operationFailed("节次加载失败")
                return []
            }
            return scheduleService.currentPeriods
        }
        function findConflicts() { return [] }
        function setPeriods(periods) {
            scheduleService.setPeriodsCallCount += 1
            var stored = []
            for (var i = 0; i < periods.length; ++i) {
                stored.push({
                    index: i + 1,
                    startMinutes: Number(periods[i].startMinutes),
                    endMinutes: Number(periods[i].endMinutes)
                })
            }
            scheduleService.currentPeriods = stored
            scheduleService.periodsChanged()
            return true
        }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged()
        function getAllCategories() {
            return [{ id: 1, name: "专业课", color: "#d4a574" }]
        }
    }

    QtObject {
        id: appSettings

        signal settingsWriteFailed(string key, string message)

        property string semesterStartDate: "2026-08-31"
        property int semesterWeeks: 16
        property bool scheduleShowWeekend: true
        property bool saveSucceeds: true

        function saveScheduleSettings(startDate, weeks, showWeekend) {
            if (!appSettings.saveSucceeds) {
                appSettings.settingsWriteFailed("schedule", "设置文件不可写")
                return false
            }
            appSettings.semesterStartDate = startDate
            appSettings.semesterWeeks = weeks
            appSettings.scheduleShowWeekend = showWeekend
            return true
        }
    }

    ScheduleEntryDialog {
        id: entryDialog

        parent: testCase
        scheduleServiceRef: scheduleService
        categoryManagerRef: categoryManager
        semesterWeeks: 16
        periods: scheduleService.getPeriods()
    }

    ScheduleSettingsDialog {
        id: settingsDialog

        parent: testCase
        scheduleServiceRef: scheduleService
        settingsRef: appSettings
    }

    QtObject {
        id: knowledgeGapService

        signal gapsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 100

        function addGap(title, categoryId, detail, priority, dueDate, sourceTaskId) { return 1 }
        function updateGap(id, title, categoryId, detail, priority, dueDate) { return true }
        function resolveGap(id, resolution) { return true }
    }

    KnowledgeGapDialog {
        id: knowledgeGapDialog

        parent: testCase
        gapServiceRef: knowledgeGapService
        categoryManagerRef: categoryManager
        todayIso: "2026-09-11"
    }

    KnowledgeGapCapturePopup {
        id: knowledgeGapCapturePopup

        parent: testCase
        gapServiceRef: knowledgeGapService
    }

    function cleanup() {
        entryDialog.close()
        settingsDialog.close()
        knowledgeGapDialog.close()
        knowledgeGapCapturePopup.close()
        wait(60)
        scheduleService.failPeriodLoad = false
        scheduleService.setPeriodsCallCount = 0
        scheduleService.currentPeriods = [
            { index: 1, startMinutes: 480, endMinutes: 525 },
            { index: 2, startMinutes: 535, endMinutes: 580 }
        ]
        entryDialog.periods = scheduleService.currentPeriods
        appSettings.saveSucceeds = true
        appSettings.semesterStartDate = "2026-08-31"
        appSettings.semesterWeeks = 16
        appSettings.scheduleShowWeekend = true
    }

    // Popup 的子项挂在 contentItem 下，不在 Popup 自己的 QObject 树里，
    // 直接对 Popup 调 findChild 找不到任何输入框。
    function fieldIn(dialog, name) {
        return findChild(dialog.contentItem, name)
    }

    function test_scheduleEntryDialogOpensForNew() {
        entryDialog.openForNew(3, 600)
        // tryVerify 而不是固定 wait：入场动画 220ms，等短了会在弹窗还没 opened 时就断言。
        tryVerify(function () { return entryDialog.opened }, 2000)
        // 预填必须落到调用方点中的那一天与时段，否则「点空白新增」就没有意义。
        compare(testCase.fieldIn(entryDialog, "scheduleWeekdayCombo").currentIndex, 2)
        compare(testCase.fieldIn(entryDialog, "scheduleStartField").text, "10:00")
        compare(testCase.fieldIn(entryDialog, "schedulePeriodCombo").currentIndex, -1)
        // 新增态不该出现删除入口。
        verify(!testCase.fieldIn(entryDialog, "scheduleDeleteButton").visible)
    }

    function test_scheduleEntryDialogOpensForEdit() {
        entryDialog.openForEdit({
            id: 5, title: "高等数学", location: "A101", weekday: 2,
            startMinutes: 480, endMinutes: 580,
            weekStart: 1, weekEnd: 8, weekParity: 1, categoryId: 1
        })
        tryVerify(function () { return entryDialog.opened }, 2000)
        compare(testCase.fieldIn(entryDialog, "scheduleTitleField").text, "高等数学")
        compare(testCase.fieldIn(entryDialog, "scheduleLocationField").text, "A101")
        compare(testCase.fieldIn(entryDialog, "scheduleParityCombo").currentIndex, 1)
        // 编辑态才有删除入口。
        verify(testCase.fieldIn(entryDialog, "scheduleDeleteButton").visible)
    }

    function test_scheduleEntryRejectsEmptyActiveWeeks() {
        entryDialog.openForEdit({
            id: 5, title: "高等数学", location: "A101", weekday: 2,
            startMinutes: 480, endMinutes: 580,
            weekStart: 1, weekEnd: 1, weekParity: 2, categoryId: 1
        })
        tryVerify(function () { return entryDialog.opened }, 2000)
        compare(entryDialog.collectInput(false), null)
        compare(entryDialog.errorField, "weekStart")
        verify(entryDialog.errorText.indexOf("没有生效周") >= 0)
        // 改成单周后同一份输入即可保存，无须关闭弹窗重新录入。
        testCase.fieldIn(entryDialog, "scheduleParityCombo").currentIndex = 1
        verify(entryDialog.collectInput(false) !== null)
    }

    function test_schedulePeriodActionStaysUnselectedWhenModelAppears() {
        entryDialog.periods = []
        entryDialog.openForNew(1, 480)
        tryVerify(function () { return entryDialog.opened }, 2000)
        var combo = testCase.fieldIn(entryDialog, "schedulePeriodCombo")
        compare(combo.currentIndex, -1)

        entryDialog.periods = scheduleService.currentPeriods
        tryCompare(combo, "count", 2)
        tryCompare(combo, "currentIndex", -1, 1000,
                   "节次模型从空变为非空时不得自动选中第 1 节")
    }

    function test_scheduleSettingsDialogOpensAndLoadsPeriods() {
        settingsDialog.openDialog()
        tryVerify(function () { return settingsDialog.opened }, 2000)
        compare(testCase.fieldIn(settingsDialog, "semesterStartField").text, "2026-08-31")
        compare(testCase.fieldIn(settingsDialog, "semesterWeeksField").text, "16")
        // 节次草稿必须从服务读进来，否则保存会把用户现有的节次表整表清空。
        compare(testCase.fieldIn(settingsDialog, "schedulePeriodList").count, 2)
    }

    function test_scheduleSettingsLoadFailureIsVisibleOnFirstOpen() {
        scheduleService.failPeriodLoad = true
        settingsDialog.openDialog()
        tryVerify(function () { return settingsDialog.opened }, 2000)
        compare(settingsDialog.errorText, "节次加载失败")
    }

    function test_scheduleSettingsFailureRollsBackPeriodsAndStaysOpen() {
        settingsDialog.openDialog()
        tryVerify(function () { return settingsDialog.opened }, 2000)
        var list = testCase.fieldIn(settingsDialog, "schedulePeriodList")
        list.model.setProperty(0, "startText", "08:05")
        appSettings.saveSucceeds = false

        settingsDialog.save()

        verify(settingsDialog.opened)
        compare(settingsDialog.errorText, "设置文件不可写")
        compare(scheduleService.setPeriodsCallCount, 2)
        compare(scheduleService.currentPeriods[0].startMinutes, 480)
        compare(appSettings.semesterStartDate, "2026-08-31")
        compare(appSettings.semesterWeeks, 16)
        compare(appSettings.scheduleShowWeekend, true)
    }

    function test_knowledgeGapDialogOpensForAdd() {
        knowledgeGapDialog.openForAdd()
        tryVerify(function () { return knowledgeGapDialog.opened }, 2000)
        compare(knowledgeGapDialog.editing, false)
        compare(testCase.fieldIn(knowledgeGapDialog, "knowledgeGapTitleField").text, "")
        // 新增默认「中」优先级、不指定科目、未排期——捕获的常态就是这三样都还没想好。
        compare(knowledgeGapDialog.selectedPriority, 1)
        compare(knowledgeGapDialog.selectedCategoryId, 0)
        compare(testCase.fieldIn(knowledgeGapDialog, "knowledgeGapDueField").text, "")
    }

    function test_knowledgeGapDialogOpensForEdit() {
        knowledgeGapDialog.openForEdit({
            id: 7,
            title: "相似对角化",
            detail: "教材第 87 页",
            categoryId: 1,
            priority: 2,
            status: 2,
            dueDate: "2026-09-20",
            resolution: "特征向量线性无关就可以"
        })
        tryVerify(function () { return knowledgeGapDialog.opened }, 2000)
        compare(knowledgeGapDialog.editing, true)
        compare(testCase.fieldIn(knowledgeGapDialog, "knowledgeGapTitleField").text, "相似对角化")
        compare(testCase.fieldIn(knowledgeGapDialog, "knowledgeGapDetailField").text, "教材第 87 页")
        compare(testCase.fieldIn(knowledgeGapDialog, "knowledgeGapDueField").text, "2026-09-20")
        compare(knowledgeGapDialog.selectedPriority, 2)
        // 已解决的条目才回填结论；未解决时那个输入框根本不该出现。
        compare(knowledgeGapDialog.resolvedState, true)
        compare(testCase.fieldIn(knowledgeGapDialog, "knowledgeGapResolutionField").text,
                "特征向量线性无关就可以")
    }

    function test_knowledgeGapDialogRejectsMalformedDueDate() {
        knowledgeGapDialog.openForAdd()
        tryVerify(function () { return knowledgeGapDialog.opened }, 2000)
        testCase.fieldIn(knowledgeGapDialog, "knowledgeGapTitleField").text = "日期填错"
        testCase.fieldIn(knowledgeGapDialog, "knowledgeGapDueField").text = "2026-02-31"

        knowledgeGapDialog.submit()

        // 2 月 31 日会被 JavaScript 的 Date 悄悄滚到 3 月 3 日；表单必须回查年月日再拒绝，
        // 否则用户等提醒的那天和实际排期的那天不是同一天。
        verify(knowledgeGapDialog.opened)
        verify(knowledgeGapDialog.errorText.length > 0)
    }

    function test_knowledgeGapCapturePopupOpens() {
        knowledgeGapCapturePopup.openWithSource(3, "复习线代第 3 章", 1)
        tryVerify(function () { return knowledgeGapCapturePopup.opened }, 2000)
        compare(knowledgeGapCapturePopup.sourceTaskId, 3)
        compare(testCase.fieldIn(knowledgeGapCapturePopup, "knowledgeGapCaptureField").text, "")
    }
}
