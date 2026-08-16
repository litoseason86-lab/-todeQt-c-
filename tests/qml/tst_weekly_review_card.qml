import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "WeeklyReviewCard"
    when: windowShown
    width: 760
    height: 520
    visible: true

    Component {
        id: cardComponent

        WeeklyReviewCard {
            width: 720
            review: ({
                hasData: true,
                plannedMinutes: 100,
                completedPomodoros: 3,
                completionRate: 105,
                focusedMinutes: 105,
                activeDays: 2,
                previousCompletedPomodoros: 0,
                previousFocusedMinutes: 0,
                previousActiveDays: 0,
                subjects: [{
                    name: "数学",
                    color: "#d4a574",
                    planned: 100,
                    actual: 3,
                    focusedMinutes: 105,
                    unplanned: false,
                    rate: 105
                }]
            })
        }
    }

    function test_subject_comparison_uses_minutes_on_both_sides() {
        var card = createTemporaryObject(cardComponent, testCase)
        verify(!!card, "Component exists")
        wait(30)

        var comparison = findChild(card, "weeklyReviewSubjectComparison")
        verify(!!comparison, "科目对账文本不存在")
        compare(comparison.text, "1 小时 45 分 / 1 小时 40 分")
    }
}
