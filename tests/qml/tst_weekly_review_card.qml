import QtQuick
import QtTest
import "../../qml/components"

// 复盘卡只按服务给的字段格式化与展示：这里用固定的服务结果驱动卡片，
// 检查各块的出现条件、固定句式与时长格式。块是否出现读卡片的 show* 属性，
// 不断言 visible === true（离屏环境里父链可见性会连带变化，结果不稳定）。
TestCase {
    id: testCase
    name: "WeeklyReviewCard"
    when: windowShown
    width: 760
    height: 720
    visible: true

    Component {
        id: cardComponent

        WeeklyReviewCard {
            width: 720
        }
    }

    function collectTexts(item, bag) {
        if (!item) {
            return bag
        }
        if (item.textFormat !== undefined && item.text !== undefined && String(item.text).length > 0) {
            bag.push(String(item.text))
        }
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) {
            collectTexts(kids[i], bag)
        }
        return bag
    }

    function findAll(item, name, bag) {
        if (!item) {
            return bag
        }
        if (item.objectName === name) {
            bag.push(item)
        }
        var kids = item.children || []
        for (var i = 0; i < kids.length; ++i) {
            findAll(kids[i], name, bag)
        }
        return bag
    }

    function currentWeekReview() {
        return {
            loadState: "ready",
            periodState: "current",
            weekStart: "2026-07-13",
            weekEnd: "2026-07-19",
            hasData: true,
            hasDisplayContent: true,
            goal: { goalDays: 2, metDays: 1, goalMinutesTotal: 120, actualSecondsTotal: 7199, days: [] },
            todayGoal: { date: "2026-07-15", goalMinutes: 30, actualSeconds: 2700, progressPercent: 150 },
            subjects: [],
            plannedTasks: {
                inProgress: true,
                totalPlannedMinutes: 150,
                totalActualSeconds: 4500,
                totalActualDisplayMinutes: 75,
                totalDifferenceDisplayMinutes: -75,
                totalInvestmentRatioPercent: 50,
                rows: [
                    { subject: "数学", color: "#d4a574", plannedMinutes: 100, actualSeconds: 3000,
                      actualDisplayMinutes: 50, differenceDisplayMinutes: -50, investmentRatioPercent: 50 },
                    { subject: "政治", color: "#be8568", plannedMinutes: 50, actualSeconds: 4500,
                      actualDisplayMinutes: 75, differenceDisplayMinutes: 25, investmentRatioPercent: 150 }
                ]
            },
            facts: []
        }
    }

    function test_currentWeekShowsOverviewWithoutFacts() {
        var card = createTemporaryObject(cardComponent, testCase, { review: currentWeekReview() })
        verify(card)
        wait(30)

        compare(findChild(card, "weeklyReviewTitle").text, "本周概览")
        compare(card.showGoal, true)
        compare(findChild(card, "weeklyReviewGoalValue").text, "1 / 2 天")
        compare(findChild(card, "weeklyReviewGoalTotals").text, "目标 2 小时 · 实际 1 小时 59 分")
        compare(card.showToday, true)
        compare(findChild(card, "weeklyReviewTodayValue").text, "150%")
        compare(findChild(card, "weeklyReviewTodayTotals").text, "目标 30 分钟 · 实际 45 分钟")

        compare(card.showPlanned, true)
        compare(findChild(card, "weeklyReviewPlannedInProgress").text, "进行中")
        compare(findChild(card, "weeklyReviewPlannedTotal").text, "1 小时 15 分 / 2 小时 30 分 · 50%")
        var amounts = findAll(card, "weeklyReviewPlannedRowAmount", [])
        compare(amounts.length, 2)
        compare(amounts[0].text, "50 分钟 / 1 小时 40 分")
        var differences = findAll(card, "weeklyReviewPlannedRowDifference", [])
        compare(differences[0].text, "-50 分钟")
        compare(differences[1].text, "+25 分钟")
        compare(findAll(card, "weeklyReviewPlannedRowRatio", [])[1].text, "150%")

        compare(card.showFacts, false)
        compare(card.errorState, false)
    }

    function test_endedWeekFactsUseFixedSentencesAndDurationFormat() {
        var review = currentWeekReview()
        review.periodState = "ended"
        review.todayGoal = {}
        review.plannedTasks.inProgress = false
        review.facts = [
            { type: "goalShortfall", date: "2026-09-09", goalMinutes: 120, actualSeconds: 3600, ratioPercent: 50 },
            { type: "subjectShareChange", subject: "数学", currentSeconds: 36000, previousSeconds: 21600,
              currentSharePercent: 45.2, deltaPoints: -12.4 },
            { type: "estimateShortfall", subject: "英语", plannedMinutes: 180,
              actualDisplayMinutes: 60, shortfallDisplayMinutes: 120 },
            { type: "estimateOnTrack", ratioPercent: 96 },
            { type: "somethingNew", subject: "数学" }
        ]
        var card = createTemporaryObject(cardComponent, testCase, { review: review })
        verify(card)
        wait(30)

        compare(findChild(card, "weeklyReviewTitle").text, "所选周复盘")
        compare(card.showToday, false)
        compare(card.plannedTasks.inProgress, false)
        // 时长统一走 Duration.js：120 分钟写成「2 小时」，不写「120 分钟」；未登记的事实类型不渲染。
        compare(card.factLines, [
            "9 月 9 日：目标 2 小时，实际 1 小时，投入为目标的 50%。",
            "数学：当周 10 小时，前一周 6 小时，占比 45%，比前一周减少 12 个百分点。",
            "英语：计划 3 小时，实际 1 小时，差 2 小时。",
            "当周有预计用时的任务，其总投入接近计划。"
        ])
        compare(findAll(card, "weeklyReviewFact", []).length, 4)
    }

    function test_errorStateShowsMessageWithoutStaleContent() {
        var review = currentWeekReview()
        review.loadState = "error"
        review.errorMessage = "no such table: focus_sessions"
        review.facts = [ { type: "estimateOnTrack", ratioPercent: 100 } ]
        var card = createTemporaryObject(cardComponent, testCase, { review: review })
        verify(card)
        wait(30)

        compare(card.errorState, true)
        compare(findChild(card, "weeklyReviewErrorTitle").text, "周统计加载失败")
        compare(findChild(card, "weeklyReviewErrorMessage").text, "no such table: focus_sessions")
        // 错误态不能带着旧数据或结论出现。
        compare(card.showGoal, false)
        compare(card.showToday, false)
        compare(card.showPlanned, false)
        compare(card.showFacts, false)
    }

    function test_noPlaceholderOrNagWhenModulesAreMissing() {
        var card = createTemporaryObject(cardComponent, testCase, { review: {
            loadState: "ready",
            periodState: "ended",
            weekStart: "2026-07-13",
            weekEnd: "2026-07-19",
            hasData: true,
            hasDisplayContent: true,
            goal: { goalDays: 0, metDays: 0, goalMinutesTotal: 0, actualSecondsTotal: 0, days: [] },
            todayGoal: {},
            subjects: [],
            plannedTasks: { rows: [], inProgress: false, totalPlannedMinutes: 0, totalActualSeconds: 0,
                            totalActualDisplayMinutes: 0, totalDifferenceDisplayMinutes: 0,
                            totalInvestmentRatioPercent: null },
            facts: [ { type: "subjectShareChange", subject: "英语", currentSeconds: 7200, previousSeconds: 3600,
                       currentSharePercent: 40, deltaPoints: 20 } ]
        } })
        verify(card)
        wait(30)

        compare(card.showGoal, false)
        compare(card.showToday, false)
        compare(card.showPlanned, false)
        compare(card.showFacts, true)
        var texts = collectTexts(card, []).join("\n")
        verify(texts.indexOf("未设置") < 0, texts)
        verify(texts.indexOf("未计划投入") < 0, texts)
        verify(texts.indexOf("预计用时后") < 0, texts)
        verify(texts.indexOf("仅统计") < 0, texts)
        compare(card.factLines[0], "英语：当周 2 小时，前一周 1 小时，占比 40%，比前一周增加 20 个百分点。")
    }
}
