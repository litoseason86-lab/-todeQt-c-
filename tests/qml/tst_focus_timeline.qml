import QtQuick
import QtQuick.Controls
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
    // 可见性会沿父链级联：根节点不可见时每个子项都读成不可见，「放得下就隐藏」那条断言就成了空话。
    visible: true
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

    function manySessions(count) {
        var rows = []
        for (var i = 0; i < count; i++) {
            rows.push({ startTime: "2026-08-08T09:00:00", endTime: "2026-08-08T09:25:00",
                        durationSeconds: 1500, taskTitle: "第 " + (i + 1) + " 段",
                        categoryName: "英语", categoryColor: "#c9956e", mode: 1 })
        }
        return rows
    }

    // 滚动条要伸到卡片外、贴窗口右缘（今日专注页传页边距 24 作为 scrollBarOverhang）。
    // ScrollView 会把挂上来的滚动条收为自己的子项并按自身边界裁剪，所以是滚动区本身
    // 向右伸出去、再用右内边距把会话卡收回卡片里。
    // 另外 ScrollView 只摆放它自己创建的滚动条：这里换了自定义样式的替身，一度漏了
    // parent/x/y/height，滚动条缩成 8x4 停在左上角，而全套测试没有一条发现它。
    function test_verticalScrollBarSitsInTheGutterOutsideTheCard() {
        var timeline = createTemporaryObject(timelineComponent, testCase,
                                             { sessions: testCase.manySessions(10), scrollBarOverhang: 24 })
        verify(timeline)

        var scrollView = findChildByObjectName(timeline, "focusTimelineScrollView")
        verify(scrollView)
        var verticalBar = findChildByObjectName(timeline, "focusTimelineVerticalScrollBar")
        verify(verticalBar)
        verify(scrollView.ScrollBar.vertical === verticalBar)

        // 内容确实超出一屏，滚动条才有意义。contentHeight 由布局 polish 阶段回填，
        // 创建后先是 -1，所以轮询等它就位。
        tryVerify(function () { return scrollView.contentHeight > scrollView.height })
        tryVerify(function () { return verticalBar.size < 1 })

        // 贴住滚动区右缘、占满视口高度——漏掉几何声明时这几条都会是 0/8x4。
        compare(verticalBar.parent, scrollView)
        compare(verticalBar.x, scrollView.width - verticalBar.width)
        compare(verticalBar.y, scrollView.topPadding)
        compare(verticalBar.height, scrollView.availableHeight)

        // 滚动区的右缘伸到卡片外 24 处，滚动条就落在那里。
        var scrollBox = scrollView.mapToItem(timeline, 0, 0)
        compare(Math.round(scrollBox.x + scrollView.width), timeline.width + 24)
        // 会话卡仍收在卡片的 16 内边距以内，不跟着伸出去，也不会被滑块压住。
        compare(Math.round(scrollBox.x + scrollView.leftPadding + scrollView.availableWidth),
                timeline.width - Theme.space16)

        // 拖滚动条要真的带动列表。
        verticalBar.position = 0.3
        tryVerify(function () { return scrollView.contentItem.contentY > 0 })
    }

    // 自定义滑块丢掉了 Basic 风格「放得下就隐藏」的逻辑，PageScrollBar 按 size 补了回来；
    // 不补时内容放得下也会画出一整条满高的滑块。只断言「不可见」，可见性断言在本项目沙箱里不可靠。
    function test_scrollBarHiddenWhenEverythingFits() {
        var timeline = createTemporaryObject(timelineComponent, testCase,
                                             { sessions: testCase.manySessions(1) })
        verify(timeline)
        var scrollView = findChildByObjectName(timeline, "focusTimelineScrollView")
        var verticalBar = findChildByObjectName(timeline, "focusTimelineVerticalScrollBar")
        verify(scrollView)
        verify(verticalBar)
        tryVerify(function () { return scrollView.contentHeight > 0 })
        tryCompare(verticalBar, "size", 1)
        compare(verticalBar.visible, false)
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
