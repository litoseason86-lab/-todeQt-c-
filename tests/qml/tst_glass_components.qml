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

    function test_valuePulseGatedByReduceMotion() {
        statCard.reduceMotionActive = false
        statCard.value = "1"
        wait(20)

        statCard.value = "2"
        tryCompare(statCard, "valuePulseRunning", true, 3000)
        tryCompare(statCard, "valuePulseRunning", false, 3000)

        statCard.reduceMotionActive = true
        statCard.value = "3"
        wait(20)
        compare(statCard.valuePulseRunning, false)
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
