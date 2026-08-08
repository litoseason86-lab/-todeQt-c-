import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 「N 小时 M 分钟」输入对。今日专注目标和任务预计用时都走这一份实现，
// 所以它的解析和越界规则一旦漂移，两处会同时错——这里把规则钉死。
TestCase {
    id: testCase
    name: "DurationFieldPair"
    when: windowShown
    width: 400
    height: 200

    Component {
        id: spyComponent

        SignalSpy {
        }
    }

    Component {
        id: pairComponent

        DurationFieldPair {
            width: 360
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

    function makePair(props) {
        var pair = createTemporaryObject(pairComponent, testCase, props)
        verify(pair)
        return pair
    }

    function test_initial_value_is_split_into_hours_and_minutes() {
        var pair = makePair({ totalMinutes: 140, namePrefix: "probe" })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")
        verify(hour)
        verify(minute)
        compare(hour.text, "2")
        compare(minute.text, "20")
        compare(pair.enteredMinutes, 140)
        compare(pair.validationError, "")
    }

    function test_entered_minutes_reads_back_the_typed_value() {
        var pair = makePair({ namePrefix: "probe" })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")

        hour.text = "1"
        minute.text = "5"
        compare(pair.enteredMinutes, 65)
        compare(pair.validationError, "")

        // 只填小时也是合法的完整输入。
        hour.text = "3"
        minute.text = "0"
        compare(pair.enteredMinutes, 180)
    }

    function test_empty_field_is_not_acceptable() {
        var pair = makePair({ namePrefix: "probe" })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")

        minute.text = ""
        compare(pair.acceptable, false)
        // 空串必须报错而不是静默按 0 处理——否则用户清空后一提交就把预计用时抹掉了。
        compare(pair.enteredMinutes, 0)
        verify(pair.validationError.length > 0)

        minute.text = "30"
        hour.text = ""
        compare(pair.acceptable, false)
    }

    function test_upper_bound_message_distinguishes_the_cap_hour() {
        var pair = makePair({ namePrefix: "probe", maximumMinutes: 24 * 60 })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")

        // 卡在整点上限：要明说分钟必须为 0，否则用户只会反复试分钟数。
        hour.text = "24"
        minute.text = "1"
        verify(pair.validationError.indexOf("分钟必须为 0") >= 0)

        hour.text = "24"
        minute.text = "0"
        compare(pair.validationError, "")
        compare(pair.enteredMinutes, 1440)
    }

    function test_maximum_is_configurable_and_clamps_the_hour_validator() {
        var pair = makePair({ namePrefix: "probe", maximumMinutes: 120 })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")

        compare(pair.maximumHours, 2)
        hour.text = "2"
        minute.text = "1"
        verify(pair.validationError.indexOf("分钟必须为 0") >= 0)

        // QIntValidator 只在位数超出上限时才判 Invalid：上限 2 小时时输入 9 属于
        // Intermediate，输入框照收。这条断言记录的就是这个真实行为——越界拦截
        // 不能指望 validator，必须由 validationError 兜住，而且提示要说清上限。
        hour.text = ""
        hour.forceActiveFocus()
        keyClick(Qt.Key_9)
        compare(hour.text, "9")
        compare(hour.acceptableInput, false)
        compare(pair.acceptable, false)
        compare(pair.enteredMinutes, 0)
        verify(pair.validationError.indexOf("不能超过 2 小时") >= 0)
    }

    function test_external_value_change_reloads_the_fields() {
        var pair = makePair({ totalMinutes: 30, namePrefix: "probe" })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")
        compare(minute.text, "30")

        pair.totalMinutes = 195
        compare(hour.text, "3")
        compare(minute.text, "15")
    }

    function test_typing_is_not_clobbered_by_a_value_change() {
        var pair = makePair({ totalMinutes: 30, namePrefix: "probe" })
        var hour = findChildByObjectName(pair, "probeHourField")
        var minute = findChildByObjectName(pair, "probeMinuteField")

        hour.forceActiveFocus()
        hour.text = "7"
        // 用户正在这两个框里打字时，外部回灌会把光标和内容一起冲掉。
        pair.totalMinutes = 600
        compare(hour.text, "7")
        compare(minute.text, "30")
    }

    function test_return_key_emits_accepted() {
        var pair = makePair({ namePrefix: "probe" })
        var hour = findChildByObjectName(pair, "probeHourField")
        var spy = createTemporaryObject(spyComponent, testCase,
                                        { target: pair, signalName: "accepted" })
        verify(spy)

        hour.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(spy.count, 1)
    }
}
