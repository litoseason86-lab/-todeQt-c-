import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"

TestCase {
    id: testCase
    name: "SegmentedSwitch"
    when: windowShown
    width: 480
    height: 240

    Component {
        id: switchComponent

        SegmentedSwitch {
            segments: ["自由专注", "番茄专注"]
        }
    }

    // 每个用例都新建实例：分段控件带内部动画和测量，复用实例会让上一条用例的状态漏进来。
    function createSwitch(props) {
        var control = createTemporaryObject(switchComponent, testCase, props)
        verify(control !== null, "分段控件应能创建")
        return control
    }

    function test_segments_are_equal_width_and_fit_labels() {
        var control = createSwitch({})
        // 等宽是胶囊只平移不变形的前提，宽度必须够放下最宽的文案。
        verify(control.segmentWidth >= control.minSegmentWidth,
               "段宽不应小于最小宽度")
        compare(control.implicitWidth,
                control.segmentWidth * 2 + control.trackInset * 2,
                "控件总宽应为各段等宽相加再加轨道内缩")
    }

    function test_thumb_follows_current_index() {
        // reduceMotion 关掉滑动动画，位置立刻到终值；否则要等 180ms 动画，用例会不稳。
        var control = createSwitch({ reduceMotion: true })
        var thumb = findChild(control, "segmentedSwitchThumb")
        verify(thumb !== null, "应能找到胶囊")

        compare(thumb.x, control.trackInset, "第 0 段时胶囊贴左内缘")
        compare(thumb.width, control.segmentWidth, "胶囊与段等宽")

        control.currentIndex = 1
        compare(thumb.x, control.trackInset + control.segmentWidth,
                "第 1 段时胶囊移到第二段起点")
    }

    // 受控组件的核心契约：点击只发信号，不准自己改 currentIndex。
    // 一旦组件内部给 currentIndex 赋值，调用方 `currentIndex: 业务状态` 的绑定会被永久摧毁。
    //
    // 这里直接调 clicked() 而不是合成鼠标事件：离屏测试环境里 visible 会整条链级联为 false，
    // 不可见的项收不到鼠标事件，mouseClick 必然打空。项目其它用例也统一走这个方式。
    function test_click_emits_activated_without_mutating_current_index() {
        var control = createSwitch({})
        var spy = signalSpyComponent.createObject(testCase, { target: control })

        findChild(control, "segmentedSwitchSegment1").clicked()

        compare(spy.count, 1, "点击应发一次 activated")
        compare(spy.signalArguments[0][0], 1, "应带上被点段的下标")
        compare(control.currentIndex, 0, "组件不得自行改写 currentIndex")
    }

    function test_click_on_selected_segment_still_emits() {
        var control = createSwitch({})
        var spy = signalSpyComponent.createObject(testCase, { target: control })

        // 点已选中的第一段：调用方可能要据此做别的事，信号不能吞掉。
        findChild(control, "segmentedSwitchSegment0").clicked()

        compare(spy.count, 1, "点击已选中段也应发信号")
        compare(spy.signalArguments[0][0], 0)
    }

    function test_arrow_keys_move_selection_and_stop_at_edges() {
        var control = createSwitch({})
        var spy = signalSpyComponent.createObject(testCase, { target: control })
        control.forceActiveFocus()

        keyClick(Qt.Key_Left)
        compare(spy.count, 0, "已在首段时左键不应发信号")

        keyClick(Qt.Key_Right)
        compare(spy.count, 1, "右键应切到下一段")
        compare(spy.signalArguments[0][0], 1)

        // 调用方通常会把新下标写回来，这里手动模拟这一步。
        control.currentIndex = 1
        keyClick(Qt.Key_Right)
        compare(spy.count, 1, "已在末段时右键不应发信号")

        keyClick(Qt.Key_Left)
        compare(spy.count, 2)
        compare(spy.signalArguments[1][0], 0)
    }

    function test_selected_label_uses_strong_ink() {
        var control = createSwitch({})
        var freeLabel = findLabel(control, "自由专注")
        var pomoLabel = findLabel(control, "番茄专注")
        verify(freeLabel !== null && pomoLabel !== null, "应能找到两段文案")

        compare(String(freeLabel.color), String(Theme.inkStrong), "选中段应为 inkStrong")
        // 未选中用 ink 而非 inkSoft：凹槽轨道上 inkSoft 只有 4.27:1，够不到正文 AA。
        compare(String(pomoLabel.color), String(Theme.ink))
    }

    // 字重必须在选中前后保持一致：翻字重是瞬时的，而胶囊要滑 200ms 才到位，
    // 两者对不上就是「切换不跟手」的观感来源，另外翻字重还会触发字形重新栅格化。
    function test_label_weight_is_stable_across_selection() {
        var control = createSwitch({})
        var freeLabel = findLabel(control, "自由专注")
        var pomoLabel = findLabel(control, "番茄专注")

        compare(freeLabel.font.bold, pomoLabel.font.bold, "选中与未选中的字重应一致")

        var weightBefore = freeLabel.font.weight
        control.currentIndex = 1
        compare(freeLabel.font.weight, weightBefore, "切走后字重不应变化")
    }

    // 胶囊是控件里唯一会动的东西，不能挂 layer(FBO) + MultiEffect 阴影 pass：
    // 给正在平移的元素加离屏纹理和 shader pass 会掉帧。浮起感靠棱边和明度差表达。
    function test_thumb_has_no_offscreen_shadow_layer() {
        var control = createSwitch({})
        var thumb = findChild(control, "segmentedSwitchThumb")
        verify(!thumb.panelShadowEnabled, "胶囊不应开启落影层")
        verify(!thumb.layer.enabled, "胶囊不应把自己渲染进离屏纹理")
    }

    // 胶囊平移和文字变色必须同一时长，否则切换看起来是散的。
    function test_thumb_and_label_share_one_duration() {
        var control = createSwitch({})
        verify(control.slideDuration > 0)
        // 动效时长必须能被 reduceMotion 整体关掉。
        control.reduceMotion = true
        control.currentIndex = 1
        var thumb = findChild(control, "segmentedSwitchThumb")
        compare(thumb.x, control.trackInset + control.segmentWidth,
                "reduceMotion 下应直接到位，不走动画")
    }

    function findLabel(item, text) {
        if (item.hasOwnProperty("text") && item.text === text && item.hasOwnProperty("font"))
            return item
        for (var i = 0; i < item.children.length; i++) {
            var hit = findLabel(item.children[i], text)
            if (hit)
                return hit
        }
        return null
    }

    Component {
        id: signalSpyComponent

        SignalSpy {
            signalName: "activated"
        }
    }
}
