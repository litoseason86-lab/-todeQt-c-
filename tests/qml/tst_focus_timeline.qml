import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// FocusTimeline 此前零测试覆盖。加 pragma ComponentBehavior: Bound 时，
// delegate 里的 modelData/index 被错误地限定到了一个嵌套 Rectangle 上，
// 整条时间轴在运行时全是 undefined——而全套 467 条断言没有一条发现它。
// 这个文件补的就是那道最小防线：delegate 真的读到了模型数据。
TestCase {
    id: testCase
    name: "FocusTimeline"
    when: windowShown
    width: 640
    height: 480

    readonly property var sampleSessions: [
        { startTime: "2026-08-08T09:00:00", endTime: "2026-08-08T09:25:00",
          durationSeconds: 1500, taskTitle: "英语阅读", categoryName: "英语",
          categoryColor: "#c9956e", mode: 1 },
        { startTime: "2026-08-08T10:00:00", endTime: "2026-08-08T10:50:00",
          durationSeconds: 3000, taskTitle: "高数强化", categoryName: "数学",
          categoryColor: "#d4a574", mode: 0 }
    ]

    Component {
        id: timelineComponent

        FocusTimeline {
            width: 600
            height: 400
        }
    }

    function findChildByObjectName(item, name) {
        if (!item) {
            return null
        }
        if (item.objectName === name) {
            return item
        }
        var slots = item.data
        if (slots === undefined || slots === null) {
            slots = item.children
        }
        if (slots === undefined || slots === null) {
            return null
        }
        for (var i = 0; i < slots.length; ++i) {
            var found = findChildByObjectName(slots[i], name)
            if (found) {
                return found
            }
        }
        return null
    }

    function collectTexts(item, bag) {
        if (!item) {
            return bag
        }
        if (item.text !== undefined && String(item.text).length > 0) {
            bag.push(String(item.text))
        }
        var slots = item.data !== undefined && item.data !== null ? item.data : item.children
        if (slots) {
            for (var i = 0; i < slots.length; ++i) {
                collectTexts(slots[i], bag)
            }
        }
        return bag
    }

    function test_delegate_actually_reads_the_model() {
        var timeline = createTemporaryObject(timelineComponent, testCase,
                                             { sessions: testCase.sampleSessions })
        verify(timeline)
        wait(50)

        // 关键断言：任务标题必须真的出现在渲染出来的文本里。
        // delegate 的 modelData 被限定错对象时，这些文本会全部变成空/undefined。
        var texts = collectTexts(timeline, [])
        verify(texts.length > 0, "时间轴应渲染出文本内容")
        verify(texts.indexOf("英语阅读") >= 0, "第一条会话的任务标题应出现")
        verify(texts.indexOf("高数强化") >= 0, "第二条会话的任务标题应出现")
        // 时长由组件自己按 durationSeconds 格式化，这里只断言「有非空时长文本」，
        // 不把格式化规则复制进测试——那样改文案就要改两处。
        verify(texts.some(function (t) { return /\d/.test(t) }), "应渲染出含数字的时长/时间文本")
    }

    function test_empty_sessions_render_without_error() {
        var timeline = createTemporaryObject(timelineComponent, testCase, { sessions: [] })
        verify(timeline)
        wait(50)
        // 空列表不该抛异常，也不该渲染出任何会话文本。
        var texts = collectTexts(timeline, [])
        verify(texts.indexOf("英语阅读") < 0)
    }
}
