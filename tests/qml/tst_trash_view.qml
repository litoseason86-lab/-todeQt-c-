import QtQuick
import QtTest
import "../../qml"
import "../../qml/views"

// 废纸篓页（计划 054 阶段 3）。服务用 QtObject 替身，记录每个方法的调用和顺序。
TestCase {
    id: testCase
    name: "TrashView"
    when: windowShown
    width: 1024
    height: 768
    // 弹层和真实鼠标事件都需要窗口真的显示。
    visible: true

    property var view: null
    property var restoredTitles: []

    QtObject {
        id: service

        signal trashChanged

        // 调用记录：「方法名」或「方法名:参数」，按发生顺序。
        property var calls: []
        property var data: []
        property string todayValue: "2026-10-07"
        property bool readOk: true
        property string readError: "读取废纸篓失败：database is locked"
        property var restoreResult: ({ ok: true, error: "", kind: "memo", title: "", conflict: "" })
        property var deleteResult: ({ ok: true, error: "" })
        property var emptyResult: ({ ok: true, error: "", count: 0 })

        function count(name) {
            var n = 0
            for (var i = 0; i < calls.length; ++i) {
                if (calls[i] === name || calls[i].indexOf(name + ":") === 0)
                    n += 1
            }
            return n
        }

        function readItems() {
            calls.push("readItems")
            if (!readOk)
                return { ok: false, error: readError, items: [] }
            return { ok: true, error: "", today: todayValue, items: data }
        }

        function purgeExpired() {
            calls.push("purgeExpired")
            return 0
        }

        function restoreItem(id) {
            calls.push("restoreItem:" + id)
            return restoreResult
        }

        function deleteItem(id) {
            calls.push("deleteItem:" + id)
            return deleteResult
        }

        function emptyTrash(ids) {
            calls.push("emptyTrash:" + (ids || []).join("|"))
            return emptyResult
        }
    }

    // 逻辑日变化信号的替身（真实的是 LogicalDayService::changed）。
    QtObject {
        id: logicalDay

        signal changed
    }

    Component {
        id: viewComponent

        TrashView {
            anchors.fill: parent
            logicalDayServiceRef: logicalDay
            onItemRestored: function (title) {
                testCase.restoredTitles = testCase.restoredTitles.concat([title])
            }
        }
    }

    function entry(id, kind, title, deletedDate, remaining, category, color, details) {
        return {
            id: id, kind: kind, title: title, deletedDate: deletedDate, remainingDays: remaining,
            categoryName: category, categoryColor: color, restorable: true, blockedReason: "",
            details: details
        }
    }

    // 设计稿里的八条（日期按 today = 2026-10-07 摆）。「还剩 N 天」故意与日期推算不一致：
    // 10-02 删的按 30 天算该剩 25，这里给 17；9-12 删的该剩 5，这里给 6。页面只能照抄数据。
    function fullData() {
        return [
            entry(1, "task", "肖秀荣 1000 题 第 3 章", "2026-10-07", 30, "政治", "#c46f5f", { date: "2026-10-06" }),
            entry(2, "focus_session", "线性代数 第 4 讲", "2026-10-07", 30, "数学", "#6f91a6",
                  { startTime: "2026-10-06T14:05:00.000", endTime: "2026-10-06T14:50:00.000", durationSeconds: 2700 }),
            entry(3, "memo", "英语一 真题进度", "2026-10-07", 30, "英语", "#9aa66b", {}),
            entry(4, "routine", "背单词 100 个", "2026-10-06", 29, "英语", "#9aa66b", { weekdays: 127 }),
            entry(5, "knowledge_gap", "泰勒公式余项的几种形式", "2026-10-06", 29, "数学", "#6f91a6", { dueDate: "2026-10-08" }),
            entry(6, "schedule_entry", "数据结构", "2026-10-02", 17, "专业课", "#b58aa0",
                  { weekday: 4, startMinutes: 840, endMinutes: 940, weekStart: 1, weekEnd: 16, weekParity: 0, location: "教三 204" }),
            entry(7, "rest_session", "主动休息", "2026-10-02", 17, "", "",
                  { startTime: "2026-10-02T21:10:00.000", endTime: "2026-10-02T21:25:00.000", durationSeconds: 900 }),
            entry(8, "countdown_goal", "全国硕士研究生招生考试", "2026-09-12", 6, "", "", { targetDate: "2026-12-19" })
        ]
    }

    function smallData() {
        return [
            entry(11, "task", "任务甲", "2026-10-07", 30, "政治", "#c46f5f", { date: "2026-10-06" }),
            entry(12, "memo", "备忘乙", "2026-10-06", 29, "", "", {})
        ]
    }

    function child(name) {
        var result = findChild(view, name)
        verify(result !== null, name)
        return result
    }

    function create(properties) {
        service.calls = []
        view = createTemporaryObject(viewComponent, testCase, properties)
        verify(view)
        // 新建出来的卡片先都在 (0,0)，布局下一帧才摆好：不等的话按坐标点按钮会落到别的行上。
        waitForRendering(view)
        verify(waitForItemPolished(view))
        return view
    }

    function init() {
        service.calls = []
        service.data = smallData()
        service.todayValue = "2026-10-07"
        service.readOk = true
        service.restoreResult = { ok: true, error: "", kind: "memo", title: "", conflict: "" }
        service.deleteResult = { ok: true, error: "" }
        service.emptyResult = { ok: true, error: "", count: 0 }
        restoredTitles = []
        view = null
    }

    function cleanup() {
        if (view) {
            // 弹层若还开着，下一条用例的焦点会留在 overlay 里。
            var dc = findChild(view, "trashDeleteConfirm")
            var ec = findChild(view, "trashEmptyConfirm")
            if (dc)
                dc.close()
            if (ec)
                ec.close()
            wait(0)
        }
    }

    // 产品保证：页面一激活就先清理到期项、再读取列表（顺序不能反，否则列表里会短暂出现已到期的项）。
    // 抓住的错误实现：激活时不调 purgeExpired，或先读后清。
    function test_activationPurgesBeforeReading() {
        create({ trashServiceRef: service, pageActive: true })
        compare(service.calls.join(","), "purgeExpired,readItems")
    }

    // 产品保证：不在这一页时收到 trashChanged 不读库；切到这一页时再清理、再读，之后的变化才跟随刷新。
    // 抓住的错误实现：常驻页面在后台也读库，或激活时不读。
    function test_inactivePageIgnoresTrashChangedUntilActivated() {
        create({ trashServiceRef: service, pageActive: false })
        compare(service.calls.length, 0, "未激活的页面创建时不读库")
        service.trashChanged()
        compare(service.calls.length, 0, "未激活时收到信号不读")
        view.pageActive = true
        compare(service.calls.join(","), "purgeExpired,readItems")
        service.calls = []
        service.trashChanged()
        compare(service.calls.join(","), "readItems", "激活后信号触发一次重读")
    }

    // 产品保证：按删除日分组，组头写「标签 · 条数」，今天 / 昨天 / 本年日期 / 跨年带年份，
    // 「还剩 N 天」取组内第一项的数据而不是页面按日期推算；没有删除日期的组写「删除时间不详」且不写剩余天数。
    function test_groupHeadingsAndRemainingDaysComeFromTheData() {
        var data = fullData()
        data.push(entry(9, "memo", "去年删的", "2025-12-31", 5, "", "", {}))
        data.push(entry(10, "memo", "没有删除时间", "", 30, "", "", {}))
        service.data = data
        create({ trashServiceRef: service })
        compare(child("trashGroupHeading-2026-10-07").text, "今天 · 3")
        compare(child("trashGroupRemaining-2026-10-07").text, "还剩 30 天")
        compare(child("trashGroupHeading-2026-10-06").text, "昨天 · 2")
        compare(child("trashGroupRemaining-2026-10-06").text, "还剩 29 天")
        compare(child("trashGroupHeading-2026-10-02").text, "10月2日 · 2")
        compare(child("trashGroupRemaining-2026-10-02").text, "还剩 17 天")
        compare(child("trashGroupHeading-2026-09-12").text, "9月12日 · 1")
        compare(child("trashGroupRemaining-2026-09-12").text, "还剩 6 天")
        compare(child("trashGroupHeading-2025-12-31").text, "2025年12月31日 · 1")
        compare(child("trashGroupHeading-unknown").text, "删除时间不详 · 1")
        compare(child("trashGroupRemaining-unknown").visible, false, "没有删除日期的组不写剩余天数")
    }

    // 产品保证：八类内容的卡片各写出标题和「类型 · 要点」，科目色点有科目时上色、没有科目不上色。
    function test_cardsShowTitleAndMetaForEveryKind() {
        service.data = fullData()
        create({ trashServiceRef: service })
        var expected = {
            1: ["肖秀荣 1000 题 第 3 章", "任务 · 10月6日 · 政治"],
            2: ["线性代数 第 4 讲", "专注记录 · 10月6日 14:05–14:50 · 45 分钟 · 数学"],
            3: ["英语一 真题进度", "备忘录 · 英语"],
            4: ["背单词 100 个", "每日例行 · 英语 · 每天"],
            5: ["泰勒公式余项的几种形式", "知识缺口 · 数学 · 计划 10月8日"],
            6: ["数据结构", "课表 · 周四 14:00–15:40 · 第 1–16 周 · 教三 204"],
            7: ["主动休息", "休息记录 · 10月2日 21:10–21:25 · 15 分钟"],
            8: ["全国硕士研究生招生考试", "倒计时 · 2026年12月19日"]
        }
        for (var id in expected) {
            compare(child("trashTitle-" + id).text, expected[id][0], "标题 " + id)
            compare(child("trashMeta-" + id).text, expected[id][1], "要点 " + id)
        }
        compare(String(child("trashDot-1").color), String(Qt.color("#c46f5f")))
        compare(child("trashDot-7").color.a, 0, "没有科目不上色")
    }

    // 产品保证：不能恢复的项「恢复」禁用、「删除」照常可点，要点写原因（认得类型时带类型名）。
    // 抓住的错误实现：对损坏或需要更新的项仍放开「恢复」。
    function test_blockedItemsDisableRestoreButKeepDelete() {
        var corrupted = entry(21, "task", "损坏的任务", "2026-10-07", 30, "", "", {})
        corrupted.restorable = false
        corrupted.blockedReason = "corrupted"
        var newer = entry(22, "future_kind", "新版本的项", "2026-10-07", 30, "", "", {})
        newer.restorable = false
        newer.blockedReason = "needsUpdate"
        service.data = [corrupted, newer, smallData()[0]]
        create({ trashServiceRef: service })
        compare(child("trashMeta-21").text, "任务 · 内容已损坏，无法恢复")
        compare(child("trashMeta-22").text, "需要更新应用后才能恢复")
        compare(child("trashRestoreButton-21").enabled, false)
        compare(child("trashRestoreButton-22").enabled, false)
        compare(child("trashRestoreButton-11").enabled, true, "能恢复的项不受影响")
        compare(child("trashDeleteButton-21").enabled, true)
        compare(child("trashDeleteButton-22").enabled, true)
    }

    // 产品保证：读取失败时提示条带「重试」、不显示「废纸篓是空的」，也不画玻璃框；点重试重读，成功后提示条消失。
    // 抓住的错误实现：读取失败按空列表处理而显示空状态。
    function test_readFailureShowsRetryAndNeverTheEmptyState() {
        service.readOk = false
        create({ trashServiceRef: service })
        compare(view.loadError, service.readError)
        compare(child("trashLoadErrorText").text, service.readError)
        compare(child("trashLoadErrorBanner").retryable, true)
        compare(child("trashLoadErrorBanner").visible, true)
        compare(child("trashEmptyStateText").visible, false, "读取失败不是空")
        compare(child("trashPanel").visible, false)
        compare(child("trashEmptyButton").enabled, false, "读取失败时清空按钮灰掉")

        service.readOk = true
        service.calls = []
        mouseClick(child("trashLoadErrorBannerRetry"))
        compare(service.calls.join(","), "readItems", "重试只重读")
        compare(view.loadError, "")
        compare(child("trashLoadErrorBanner").visible, false)
        compare(child("trashPanel").visible, true)
        compare(child("trashEmptyButton").enabled, true)
    }

    // 产品保证：读取成功且没有项时，只在页面中间写「废纸篓是空的」，不画玻璃框，「清空废纸篓」灰掉不可点。
    function test_emptyStateHidesPanelAndDisablesEmptyButton() {
        service.data = []
        create({ trashServiceRef: service })
        compare(child("trashEmptyStateText").text, "废纸篓是空的")
        compare(child("trashEmptyStateText").visible, true)
        compare(child("trashPanel").visible, false)
        compare(child("trashEmptyButton").enabled, false)
        compare(child("trashLoadErrorBanner").visible, false)
    }

    // 产品保证：恢复成功就发 itemRestored(标题) 并重读列表；之前的操作失败提示随之清掉。
    // 数据：先让一次恢复失败留下提示条，再恢复成功。
    function test_restoreSuccessEmitsSignalAndClearsPreviousError() {
        create({ trashServiceRef: service })
        service.restoreResult = { ok: false, error: "恢复失败：磁盘已满", kind: "task", title: "任务甲", conflict: "" }
        mouseClick(child("trashRestoreButton-11"))
        compare(view.actionError, "没能恢复「任务甲」：恢复失败：磁盘已满")
        compare(restoredTitles.length, 0)

        service.restoreResult = { ok: true, error: "", kind: "task", title: "任务甲", conflict: "" }
        service.calls = []
        mouseClick(child("trashRestoreButton-11"))
        compare(restoredTitles.join("|"), "任务甲")
        compare(service.calls.join(","), "restoreItem:11,readItems")
        compare(view.actionError, "", "操作成功清掉失败提示")
        compare(child("trashActionErrorBanner").visible, false)
    }

    // 产品保证：恢复专注记录撞上别的记录时，提示条写出这一项的时间段和服务给的原因，这一项仍留在列表里。
    // 抓住的错误实现：冲突时不拼时间段，或失败后把这一项从列表里拿掉。
    function test_restoreConflictNamesTheTimeSpanAndKeepsTheItem() {
        service.data = [entry(2, "focus_session", "线性代数 第 4 讲", "2026-10-07", 30, "数学", "#6f91a6",
                              { startTime: "2026-10-06T14:05:00.000", endTime: "2026-10-06T14:50:00.000", durationSeconds: 2700 })]
        create({ trashServiceRef: service })
        service.restoreResult = { ok: false, error: "这段时间已有别的专注记录", kind: "focus_session",
                                  title: "线性代数 第 4 讲", conflict: "focus" }
        mouseClick(child("trashRestoreButton-2"))
        compare(child("trashActionErrorText").text,
                "没能恢复「线性代数 第 4 讲」：10月6日 14:05–14:50 这段时间已有别的专注记录")
        compare(child("trashActionErrorBanner").retryable, false, "操作失败的提示条不带重试")
        compare(restoredTitles.length, 0)
        verify(findChild(view, "trashRow-2") !== null, "失败的这一项还在列表里")
        compare(service.count("restoreItem"), 1)
    }

    // 产品保证：另一台刚把这一项恢复或删掉时（服务给 code "gone"），提示「已经不在废纸篓里了」并重读列表，列表跟着变。
    // 重读认的是结构化的 code，不是提示文案：先给一次文案相同、但没有 code 的失败，确认它不重读。
    function test_restoreOfAnAlreadyGoneItemRefreshesTheList() {
        create({ trashServiceRef: service })
        service.restoreResult = { ok: false, error: "这一项已经不在废纸篓里了", kind: "", title: "", conflict: "" }
        service.calls = []
        mouseClick(child("trashRestoreButton-11"))
        compare(service.calls.join(","), "restoreItem:11", "没有 code 的失败只提示、不重读")

        service.restoreResult = { ok: false, error: "这一项已经不在废纸篓里了", code: "gone" }
        service.data = [smallData()[1]]
        service.calls = []
        mouseClick(child("trashRestoreButton-11"))
        compare(view.actionError, "没能恢复「任务甲」：这一项已经不在废纸篓里了")
        compare(service.calls.join(","), "restoreItem:11,readItems")
        // 旧卡片是延迟销毁的，等它真的离开对象树。
        tryVerify(function () { return findChild(view, "trashRow-11") === null }, 3000)
    }

    // 产品保证：彻底删除时这一项已经不在了（code "gone"），同样提示后重读列表。
    function test_deleteOfAnAlreadyGoneItemRefreshesTheList() {
        create({ trashServiceRef: service })
        service.deleteResult = { ok: false, error: "这一项已经不在废纸篓里了", code: "gone" }
        mouseClick(child("trashDeleteButton-11"))
        tryVerify(function () { return child("trashDeleteConfirm").opened }, 3000)
        service.data = [smallData()[1]]
        service.calls = []
        mouseClick(child("trashDeleteConfirmButton"))
        compare(view.actionError, "这一项已经不在废纸篓里了")
        compare(service.calls.join(","), "deleteItem:11,readItems")
        tryVerify(function () { return findChild(view, "trashRow-11") === null }, 3000)
    }

    // 产品保证：重新进入这一页时，上次留下的操作失败提示清掉（它说的是那时的列表，已经过期）。
    // 数据：先让一次恢复失败留下提示条，离开再回来。
    function test_reenteringThePageClearsAnOldActionError() {
        create({ trashServiceRef: service })
        service.restoreResult = { ok: false, error: "恢复失败：磁盘已满", kind: "task", title: "任务甲", conflict: "" }
        mouseClick(child("trashRestoreButton-11"))
        compare(child("trashActionErrorBanner").visible, true, "前提：留下了失败提示")
        view.pageActive = false
        compare(child("trashActionErrorBanner").visible, true, "离开时不动它")
        view.pageActive = true
        compare(view.actionError, "")
        compare(child("trashActionErrorBanner").visible, false)
    }

    // 产品保证：「删除」先弹确认，焦点落在「取消」，Esc 关闭且不调用服务；点「删除」确认后调用一次并重读。
    // 抓住的错误实现：焦点不在「取消」（回车会误删）、Esc 无效、或确认前就调用服务。
    function test_deleteConfirmFocusEscapeAndConfirm() {
        create({ trashServiceRef: service })
        var popup = child("trashDeleteConfirm")
        mouseClick(child("trashDeleteButton-11"))
        tryVerify(function () { return popup.opened }, 3000)
        compare(child("trashDeleteConfirmText").text, "任务甲", "确认框写出是哪一项")
        tryVerify(function () { return child("trashDeleteCancel").activeFocus }, 3000)
        compare(service.count("deleteItem"), 0, "确认前不调用服务")
        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !popup.opened }, 3000)
        compare(service.count("deleteItem"), 0, "Esc 关闭不删除")

        mouseClick(child("trashDeleteButton-11"))
        tryVerify(function () { return popup.opened }, 3000)
        service.calls = []
        mouseClick(child("trashDeleteConfirmButton"))
        compare(service.calls.join(","), "deleteItem:11,readItems")
        tryVerify(function () { return !popup.opened }, 3000)
    }

    // 产品保证：彻底删除失败时，提示条直接写服务给的原因，这一项还在。
    function test_deleteFailureShowsTheServiceReason() {
        create({ trashServiceRef: service })
        service.deleteResult = { ok: false, error: "删除失败：database is locked" }
        mouseClick(child("trashDeleteButton-11"))
        tryVerify(function () { return child("trashDeleteConfirm").opened }, 3000)
        mouseClick(child("trashDeleteConfirmButton"))
        compare(child("trashActionErrorText").text, "删除失败：database is locked")
        verify(findChild(view, "trashRow-11") !== null)
    }

    // 产品保证：「清空废纸篓」先弹确认，标题里的 N 是列表当前的项数，焦点在「取消」，Esc 关闭不清空；
    // 点「清空」调用一次。数据是 3 条而不是 1 或 2，防止把 N 写死或取成组数。
    function test_emptyConfirmShowsCountAndRequiresConfirmation() {
        service.data = smallData().concat([entry(13, "memo", "备忘丙", "2026-10-06", 29, "", "", {})])
        create({ trashServiceRef: service })
        compare(view.groups.length, 2, "前提：两组、三项")
        var popup = child("trashEmptyConfirm")
        mouseClick(child("trashEmptyButton"))
        tryVerify(function () { return popup.opened }, 3000)
        compare(child("trashEmptyConfirmTitle").text, "彻底删除废纸篓里的 3 项？")
        tryVerify(function () { return child("trashEmptyCancel").activeFocus }, 3000)
        keyClick(Qt.Key_Escape)
        tryVerify(function () { return !popup.opened }, 3000)
        compare(service.count("emptyTrash"), 0)

        mouseClick(child("trashEmptyButton"))
        tryVerify(function () { return popup.opened }, 3000)
        service.calls = []
        mouseClick(child("trashEmptyConfirmButton"))
        compare(service.calls.join(","), "emptyTrash:11|12|13,readItems")
    }

    // 产品保证：清空只删确认框打开那一刻列出的项，确认期间同步进来的新项不会被一起删掉。
    // 数据：打开确认框时是 11、12 两项；框开着时服务端多出 13 并通知页面重读，点「清空」传给服务的只能是 11、12。
    function test_emptyDeletesOnlyTheItemsListedWhenTheConfirmOpened() {
        service.data = smallData()
        create({ trashServiceRef: service })
        var popup = child("trashEmptyConfirm")
        mouseClick(child("trashEmptyButton"))
        tryVerify(function () { return popup.opened }, 3000)
        compare(child("trashEmptyConfirmTitle").text, "彻底删除废纸篓里的 2 项？")

        service.data = smallData().concat([entry(13, "memo", "备忘丙", "2026-10-06", 29, "", "", {})])
        service.trashChanged()
        compare(view.items.length, 3, "前提：列表已重读成三项")
        verify(popup.opened, "前提：确认框仍开着")
        compare(child("trashEmptyConfirmTitle").text, "彻底删除废纸篓里的 2 项？")

        service.calls = []
        mouseClick(child("trashEmptyConfirmButton"))
        verify(service.calls.indexOf("emptyTrash:11|12") >= 0, service.calls.join(","))
        verify(service.calls.join(",").indexOf("13") < 0, "不含确认后新进来的 13：" + service.calls.join(","))
    }

    // 产品保证：停在废纸篓页跨过日界点时页面重读，即使没有项到期（没有 trashChanged）：「今天」分组和剩余天数照样要变。
    // 不在当前页时不读库。
    function test_logicalDayChangeRereadsEvenWithoutExpiredItems() {
        service.data = [entry(21, "memo", "备忘丁", "2026-10-07", 30, "", "", {})]
        service.todayValue = "2026-10-07"
        create({ trashServiceRef: service })
        compare(child("trashGroupHeading-2026-10-07").text, "今天 · 1")
        compare(child("trashGroupRemaining-2026-10-07").text, "还剩 30 天")

        service.todayValue = "2026-10-08"
        service.data = [entry(21, "memo", "备忘丁", "2026-10-07", 29, "", "", {})]
        logicalDay.changed()
        tryCompare(child("trashGroupHeading-2026-10-07"), "text", "昨天 · 1")
        compare(child("trashGroupRemaining-2026-10-07").text, "还剩 29 天")

        view.pageActive = false
        service.calls = []
        logicalDay.changed()
        compare(service.count("readItems"), 0, "不在当前页不读库")
    }

    // 产品保证：清空失败时提示条写服务给的原因，列表不动。
    function test_emptyFailureShowsTheServiceReason() {
        create({ trashServiceRef: service })
        service.emptyResult = { ok: false, error: "清空失败：database is locked" }
        mouseClick(child("trashEmptyButton"))
        tryVerify(function () { return child("trashEmptyConfirm").opened }, 3000)
        mouseClick(child("trashEmptyConfirmButton"))
        compare(child("trashActionErrorText").text, "清空失败：database is locked")
        verify(findChild(view, "trashRow-11") !== null)
    }

    // 产品保证：iPad（触屏）上卡片按钮、页头按钮和两个确认弹层的按钮高 44；Mac 上是 Theme.controlHeightMd。
    function test_touchUiButtonHeights_data() {
        return [
            { tag: "触屏", touch: true, height: 44 },
            { tag: "桌面", touch: false, height: Theme.controlHeightMd }
        ]
    }

    function test_touchUiButtonHeights(data) {
        create({ trashServiceRef: service, touchUi: data.touch })
        compare(child("trashRestoreButton-11").height, data.height)
        compare(child("trashDeleteButton-11").height, data.height)
        compare(child("trashEmptyButton").height, data.height)
        view.requestDelete(service.data[0])
        tryVerify(function () { return child("trashDeleteConfirm").opened }, 3000)
        compare(child("trashDeleteCancel").height, data.height)
        compare(child("trashDeleteConfirmButton").height, data.height)
        child("trashDeleteConfirm").close()
        tryVerify(function () { return !child("trashDeleteConfirm").opened }, 3000)
        view.requestEmpty()
        tryVerify(function () { return child("trashEmptyConfirm").opened }, 3000)
        compare(child("trashEmptyCancel").height, data.height)
        compare(child("trashEmptyConfirmButton").height, data.height)
    }

    // 产品保证：卡片上两个按钮的无障碍名字带上标题，读屏用户分得清是哪一项。
    function test_buttonsCarryTheTitleInTheirAccessibleNames() {
        create({ trashServiceRef: service })
        compare(child("trashRestoreButton-11").Accessible.name, "恢复「任务甲」")
        compare(child("trashDeleteButton-11").Accessible.name, "彻底删除「任务甲」")
    }
}
