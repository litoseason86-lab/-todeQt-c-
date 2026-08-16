import QtQuick
import QtQuick.Layouts
import "../Duration.js" as Duration
import ".."

// 每周复盘卡片：计划 vs 实际、与上周对比、科目对账、确定性事实+建议。
// 只展示 StatisticsService.getWeeklyReview 给出的数据，不在 QML 里做任何统计计算。
Rectangle {
    id: root

    property var review: ({})
    property bool isCurrentPeriod: true

    readonly property bool hasData: root.review && root.review.hasData === true
    // 分钟转「N 小时 M 分」，与今日专注目标同一种读法。
    readonly property int planned: root.review ? Number(root.review.plannedMinutes || 0) : 0
    readonly property int completed: root.review ? Number(root.review.completedPomodoros || 0) : 0
    readonly property real rate: root.review ? Number(root.review.completionRate || 0) : 0
    readonly property var subjects: root.review && root.review.subjects ? root.review.subjects : []
    readonly property string factText: root.review && root.review.factText ? root.review.factText : ""
    readonly property string suggestion: root.review && root.review.suggestionText ? root.review.suggestionText : ""

    Layout.fillWidth: true
    Layout.bottomMargin: Theme.space24
    implicitHeight: content.implicitHeight + Theme.space24 * 2
    radius: Theme.radiusLg
    color: Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1

    function signedInt(value) {
        return (value >= 0 ? "+" : "") + value
    }

    function signedHours(minutes) {
        var h = minutes / 60
        return (h >= 0 ? "+" : "") + h.toFixed(1) + " 小时"
    }

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.space24
        spacing: Theme.space16

        // 标题 + 日期范围
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                text: root.isCurrentPeriod ? "本周复盘" : "所选周复盘"
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
            }

            Text {
                visible: Boolean(root.review && root.review.weekStart)
                text: (root.review && root.review.weekStart ? root.review.weekStart : "") + " 至 "
                      + (root.review && root.review.weekEnd ? root.review.weekEnd : "")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
        }

        // 空状态
        Text {
            objectName: "weeklyReviewEmptyText"
            Layout.fillWidth: true
            visible: !root.hasData
            text: "本周还没有足够的计划和专注数据。\n完成几个带预估的任务后，这里会生成计划偏差分析。"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
            lineHeight: 1.3
        }

        // 计划 / 实际 / 完成率
        RowLayout {
            Layout.fillWidth: true
            visible: root.hasData
            spacing: Theme.space24

            Repeater {
                model: [
                    { label: "计划用时", value: root.planned > 0 ? Duration.format(root.planned) : "未设置" },
                    { label: "实际投入", value: Duration.format(Number(root.review ? root.review.focusedMinutes || 0 : 0)) },
                    { label: "计划完成率", value: root.planned > 0 ? Math.round(root.rate) + "%" : "未设置" }
                ]

                ColumnLayout {
                    required property var modelData
                    spacing: 2

                    Text {
                        text: parent.modelData.value
                        textFormat: Text.PlainText
                        color: Theme.accentInk
                        font.pixelSize: Theme.fontXxl
                        font.weight: Font.Bold
                        font.family: Theme.fontFamilyData
                    }

                    Text {
                        text: parent.modelData.label
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontSm
                    }
                }
            }
        }

        // 与上周对比
        RowLayout {
            Layout.fillWidth: true
            visible: root.hasData
            spacing: Theme.space16

            Text {
                text: "比上周："
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            Text {
                text: "专注时长 " + root.signedHours(Number(root.review.focusedMinutes || 0) - Number(root.review.previousFocusedMinutes || 0))
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Text {
                text: "有效番茄 " + root.signedInt(root.completed - Number(root.review.previousCompletedPomodoros || 0))
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Text {
                text: "活跃天数 " + root.signedInt(Number(root.review.activeDays || 0) - Number(root.review.previousActiveDays || 0))
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Item { Layout.fillWidth: true }
        }

        // 科目对账
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.hasData && root.subjects.length > 0
            spacing: Theme.space8

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            Repeater {
                model: root.subjects

                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.space8

                    Rectangle {
                        Layout.preferredWidth: 10
                        Layout.preferredHeight: 10
                        radius: 5
                        color: parent.modelData.color || Theme.accent
                    }

                    Text {
                        Layout.fillWidth: true
                        text: parent.modelData.name || "未分类"
                        textFormat: Text.PlainText
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }

                    Text {
                        objectName: "weeklyReviewSubjectComparison"
                        // 计划和实际都以分钟为底层单位，再统一格式化成人类可读时长。
                        // completedPomodoros 是独立事实，不能拿“个数”去除以“分钟”。
                        text: Duration.format(Number(parent.modelData.focusedMinutes || 0))
                              + " / " + Duration.format(Number(parent.modelData.planned || 0))
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        font.family: Theme.fontFamilyData
                    }

                    Text {
                        Layout.preferredWidth: 88
                        horizontalAlignment: Text.AlignRight
                        text: parent.modelData.unplanned === true
                              ? "未计划投入"
                              : (Math.round(Number(parent.modelData.rate || 0)) + "%")
                        textFormat: Text.PlainText
                        color: parent.modelData.unplanned === true ? Theme.inkMuted : Theme.accentInk
                        font.pixelSize: Theme.fontSm
                    }
                }
            }
        }

        // 事实结论 + 建议
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.hasData && (root.factText.length > 0 || root.suggestion.length > 0)
            spacing: Theme.space8

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            Text {
                objectName: "weeklyReviewFactText"
                Layout.fillWidth: true
                visible: root.factText.length > 0
                text: root.factText
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.suggestion.length > 0
                spacing: Theme.space8

                Rectangle {
                    Layout.preferredWidth: 3
                    Layout.fillHeight: true
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    radius: 1.5
                    color: Theme.accent
                }

                Text {
                    objectName: "weeklyReviewSuggestionText"
                    Layout.fillWidth: true
                    text: root.suggestion
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                }
            }
        }
    }
}
