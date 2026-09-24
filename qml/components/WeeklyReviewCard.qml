pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../Duration.js" as Duration
import ".."

// 每周复盘卡片。当前周只看概览（已结束日的目标达成、今日进度、进行中的预计用时任务），
// 已结束周再给最多两条事实。命中哪条规则、选哪天哪科、比例与展示分钟都由
// StatisticsService.getWeeklyReview 决定；这里只按字段格式化与展示：不算比例、不挑事实、不含阈值。
// 玻璃卡的底色、白色描边、圆角、顶部高光和落影都由 GlassPanel 统一提供，与各页面的玻璃框同一套。
GlassPanel {
    id: root

    property var review: ({})

    readonly property bool errorState: root.review.loadState === "error"
    readonly property bool currentWeek: root.review.periodState === "current"
    readonly property var goal: root.review.goal || ({})
    readonly property var todayGoal: root.review.todayGoal || ({})
    readonly property var plannedTasks: root.review.plannedTasks || ({})
    readonly property var plannedRows: root.plannedTasks.rows || []
    readonly property bool showGoal: !root.errorState && Number(root.goal.goalDays || 0) > 0
    readonly property bool showToday: !root.errorState && Number(root.todayGoal.goalMinutes || 0) > 0
    readonly property bool showPlanned: !root.errorState && root.plannedRows.length > 0
    // 事实按类型套固定句式；未登记的类型得到空串，不渲染。
    readonly property var factLines: {
        var lines = []
        var facts = root.errorState ? [] : (root.review.facts || [])
        for (var i = 0; i < facts.length; i++) {
            var line = root.factText(facts[i])
            if (line.length > 0) {
                lines.push(line)
            }
        }
        return lines
    }
    readonly property bool showFacts: root.factLines.length > 0

    implicitHeight: content.implicitHeight + Theme.space24 * 2

    function percentText(value) {
        return Math.round(Number(value || 0)) + "%"
    }

    function signedMinutes(minutes) {
        var value = Number(minutes || 0)
        if (value === 0) {
            return Duration.format(0)
        }
        return (value > 0 ? "+" : "-") + Duration.format(Math.abs(value))
    }

    // 服务给的是 yyyy-MM-dd，直接取月日两个整数，不构造 Date，避免时区换算。
    function dateText(isoDate) {
        var parts = String(isoDate || "").split("-")
        return parts.length === 3 ? Number(parts[1]) + " 月 " + Number(parts[2]) + " 日" : ""
    }

    function factText(fact) {
        if (!fact) {
            return ""
        }
        switch (fact.type) {
        case "goalShortfall":
            return root.dateText(fact.date) + "：目标 " + Duration.format(fact.goalMinutes)
                    + "，实际 " + Duration.formatSeconds(fact.actualSeconds)
                    + "，投入为目标的 " + root.percentText(fact.ratioPercent) + "。"
        case "subjectShareChange": {
            var delta = Number(fact.deltaPoints || 0)
            return String(fact.subject || "") + "：当周 " + Duration.formatSeconds(fact.currentSeconds)
                    + "，前一周 " + Duration.formatSeconds(fact.previousSeconds)
                    + "，占比 " + root.percentText(fact.currentSharePercent)
                    + "，比前一周" + (delta >= 0 ? "增加 " : "减少 ")
                    + Math.round(Math.abs(delta)) + " 个百分点。"
        }
        case "estimateShortfall":
            return String(fact.subject || "") + "：计划 " + Duration.format(fact.plannedMinutes)
                    + "，实际 " + Duration.format(fact.actualDisplayMinutes)
                    + "，差 " + Duration.format(fact.shortfallDisplayMinutes) + "。"
        case "estimateOnTrack":
            return "当周有预计用时的任务，其总投入接近计划。"
        default:
            return ""
        }
    }

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.space24
        spacing: Theme.space16

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                objectName: "weeklyReviewTitle"
                text: root.currentWeek ? "本周概览" : "所选周复盘"
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
            }

            Text {
                visible: text.length > 0
                text: root.review.weekStart && root.review.weekEnd
                      ? root.review.weekStart + " 至 " + root.review.weekEnd : ""
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.errorState
            spacing: Theme.space4

            Text {
                objectName: "weeklyReviewErrorTitle"
                text: "周统计加载失败"
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
            }

            Text {
                objectName: "weeklyReviewErrorMessage"
                Layout.fillWidth: true
                visible: text.length > 0
                text: String(root.review.errorMessage || "")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.showGoal || root.showToday
            spacing: Theme.space32

            ColumnLayout {
                visible: root.showGoal
                spacing: 2

                Text {
                    objectName: "weeklyReviewGoalValue"
                    text: Number(root.goal.metDays || 0) + " / " + Number(root.goal.goalDays || 0) + " 天"
                    textFormat: Text.PlainText
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
                    font.family: Theme.fontFamilyData
                }

                Text {
                    text: "目标达成"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                Text {
                    objectName: "weeklyReviewGoalTotals"
                    text: "目标 " + Duration.format(root.goal.goalMinutesTotal)
                          + " · 实际 " + Duration.formatSeconds(root.goal.actualSecondsTotal)
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }
            }

            ColumnLayout {
                visible: root.showToday
                spacing: 2

                Text {
                    objectName: "weeklyReviewTodayValue"
                    text: root.percentText(root.todayGoal.progressPercent)
                    textFormat: Text.PlainText
                    color: Theme.accentInk
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
                    font.family: Theme.fontFamilyData
                }

                Text {
                    text: "今日进度"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                Text {
                    objectName: "weeklyReviewTodayTotals"
                    text: "目标 " + Duration.format(root.todayGoal.goalMinutes)
                          + " · 实际 " + Duration.formatSeconds(root.todayGoal.actualSeconds)
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }
            }

            Item {
                Layout.fillWidth: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.showPlanned
            spacing: Theme.space8

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
                Accessible.ignored: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                Text {
                    text: "预计用时任务"
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                }

                Text {
                    objectName: "weeklyReviewPlannedInProgress"
                    visible: root.plannedTasks.inProgress === true
                    text: "进行中"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                Item {
                    Layout.fillWidth: true
                }

                Text {
                    objectName: "weeklyReviewPlannedTotal"
                    text: Duration.format(root.plannedTasks.totalActualDisplayMinutes)
                          + " / " + Duration.format(root.plannedTasks.totalPlannedMinutes)
                          + " · " + root.percentText(root.plannedTasks.totalInvestmentRatioPercent)
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamilyData
                }
            }

            Repeater {
                model: root.plannedRows

                RowLayout {
                    id: plannedRow

                    required property var modelData

                    Layout.fillWidth: true
                    spacing: Theme.space8

                    Rectangle {
                        Layout.preferredWidth: 10
                        Layout.preferredHeight: 10
                        radius: 5
                        color: plannedRow.modelData.color || Theme.accent
                        Accessible.ignored: true
                    }

                    Text {
                        Layout.fillWidth: true
                        text: String(plannedRow.modelData.subject || "")
                        textFormat: Text.PlainText
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }

                    Text {
                        objectName: "weeklyReviewPlannedRowAmount"
                        text: Duration.format(plannedRow.modelData.actualDisplayMinutes)
                              + " / " + Duration.format(plannedRow.modelData.plannedMinutes)
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamilyData
                    }

                    Text {
                        objectName: "weeklyReviewPlannedRowDifference"
                        Layout.preferredWidth: 96
                        horizontalAlignment: Text.AlignRight
                        text: root.signedMinutes(plannedRow.modelData.differenceDisplayMinutes)
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamilyData
                    }

                    Text {
                        objectName: "weeklyReviewPlannedRowRatio"
                        Layout.preferredWidth: 56
                        horizontalAlignment: Text.AlignRight
                        text: root.percentText(plannedRow.modelData.investmentRatioPercent)
                        textFormat: Text.PlainText
                        color: Theme.accentInk
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamilyData
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.showFacts
            spacing: Theme.space8

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
                Accessible.ignored: true
            }

            Repeater {
                model: root.factLines

                Text {
                    id: factLine

                    required property string modelData

                    objectName: "weeklyReviewFact"
                    Layout.fillWidth: true
                    text: factLine.modelData
                    textFormat: Text.PlainText
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontMd
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                }
            }
        }
    }
}
