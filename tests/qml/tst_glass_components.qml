import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 共享卡片组件的玻璃化守门测试：断言驱动属性（color 令牌），不做像素级检查。
TestCase {
    id: testCase
    name: "GlassComponents"
    when: windowShown
    // 玻璃卡的落影图层只在可见时开启（GlassPanel 的约定），要断言图层就得让用例真的可见。
    visible: true
    width: 420
    height: 320

    StatCard {
        id: statCard

        title: "专注"
        value: "0"
    }

    ChartBar {
        id: chartBar

        width: 300
        height: 160
    }

    ChartPie {
        id: chartPie

        width: 300
        height: 160
    }

    CountdownItem {
        id: countdownItem

        y: 170
        width: 300
        goalName: "考研"
    }

    function test_statCardGlass() {
        verify(Qt.colorEqual(statCard.color, Theme.glassCard))
        verify(Qt.colorEqual(statCard.border.color, Theme.glassBorder))
    }

    function test_statCardValueUsesDataFamily() {
        var valueText = findChild(statCard, "statCardValue")
        verify(valueText)
        compare(valueText.font.family, Theme.fontFamilyData)
    }

    // 产品保证：数值变化时从原大小放大到 1.05 再回到原样；减少动态效果时不启动脉冲。
    function test_valuePulseGatedByReduceMotion() {
        var previousReduceMotion = Theme.reduceMotion
        try {
            Theme.reduceMotion = false
            statCard.reduceMotionActive = true
            statCard.value = "1"
            var valueText = findChild(statCard, "statCardValue")
            verify(valueText !== null)
            compare(valueText.scale, 1, "前置：脉冲从原大小开始")
            compare(statCard.valuePulseRunning, false)

            // 动画是数值文字 data 中的非可视对象；不为测试给产品新增公开入口。
            var pulses = []
            for (var i = 0; i < valueText.data.length; ++i) {
                if (valueText.data[i] instanceof SequentialAnimation)
                    pulses.push(valueText.data[i])
            }
            compare(pulses.length, 1, "数值文字只配置一组顺序脉冲")
            var animations = pulses[0].animations
            compare(animations.length, 2)
            // 组件没有显式 from；用起步的 scale 和串联的两个终点核对 1→1.05→1，避免把默认 from 读值当成起点。
            var endpoints = [1.05, 1]
            for (var j = 0; j < animations.length; ++j) {
                verify(animations[j] instanceof NumberAnimation)
                compare(animations[j].target, valueText)
                compare(animations[j].property, "scale")
                compare(animations[j].to, endpoints[j])
                verify(animations[j].duration > 0, "允许动效时两段缩放都有时长")
            }

            // 先记录通知，再改变数值；慢机器错过整个 300 ms 脉冲也不会漏掉已发生的开始、结束通知。
            var spy = createTemporaryQmlObject('import QtTest; SignalSpy { signalName: "valuePulseRunningChanged" }', testCase)
            verify(spy !== null)
            spy.target = statCard
            verify(spy.valid, "前置：能监听脉冲运行状态的变化")
            statCard.reduceMotionActive = false
            spy.clear()
            statCard.value = "2"
            tryCompare(statCard, "valuePulseRunning", false, 3000)
            verify(spy.count >= 2, "脉冲记录了开始和结束")
            compare(valueText.scale, 1)

            statCard.reduceMotionActive = true
            spy.clear()
            statCard.value = "3"
            compare(statCard.valuePulseRunning, false)
            compare(spy.count, 0, "减少动效时没有启动脉冲")
            compare(valueText.scale, 1)
        } finally {
            statCard.reduceMotionActive = true
            Theme.reduceMotion = previousReduceMotion
        }
    }

    // 柱图、饼图原先圆角 6、没有落影，和同一页的统计卡不一致；现在都是 GlassPanel。
    function test_chartBarGlass() {
        verify(Qt.colorEqual(chartBar.color, Theme.glassCard))
        verify(Qt.colorEqual(chartBar.border.color, Theme.glassBorder))
        compare(chartBar.radius, Theme.radiusLg)
        compare(chartBar.panelShadowEnabled, true)
    }

    function test_chartPieGlass() {
        verify(Qt.colorEqual(chartPie.color, Theme.glassCard))
        verify(Qt.colorEqual(chartPie.border.color, Theme.glassBorder))
        compare(chartPie.radius, Theme.radiusLg)
        compare(chartPie.panelShadowEnabled, true)
    }

    function test_countdownItemGlassKeepsHoverBorder() {
        verify(Qt.colorEqual(countdownItem.color, Theme.glassCard))
        // 默认态（无悬停）边框与其它玻璃卡统一为 Theme.glassBorder。
        verify(Qt.colorEqual(countdownItem.border.color, Theme.glassBorder))
        tryCompare(countdownItem.layer, "enabled", true)

        // 悬停只能改描边色，不能让落影图层跟着开关：指针事件分发期间重建效果层，
        // Qt Quick 的 hover 命中树可能留下失效项指针。
        mouseMove(countdownItem, 20, 20)
        tryVerify(function () { return Qt.colorEqual(countdownItem.border.color, Theme.accent) })
        compare(countdownItem.layer.enabled, true)
        mouseMove(testCase, 400, 10)
        tryVerify(function () { return Qt.colorEqual(countdownItem.border.color, Theme.glassBorder) })
        compare(countdownItem.layer.enabled, true)
    }
}
