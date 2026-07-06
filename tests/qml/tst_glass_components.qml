import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 共享卡片组件的玻璃化守门测试：断言驱动属性（color 令牌），不做像素级检查。
TestCase {
    id: testCase
    name: "GlassComponents"
    when: windowShown
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

        width: 300
        goalName: "考研"
    }

    function test_statCardGlass() {
        verify(Qt.colorEqual(statCard.color, Theme.glassCard))
        verify(Qt.colorEqual(statCard.border.color, Theme.glassBorder))
    }

    function test_chartBarGlass() {
        verify(Qt.colorEqual(chartBar.color, Theme.glassCard))
        verify(Qt.colorEqual(chartBar.border.color, Theme.glassBorder))
    }

    function test_chartPieGlass() {
        verify(Qt.colorEqual(chartPie.color, Theme.glassCard))
        verify(Qt.colorEqual(chartPie.border.color, Theme.glassBorder))
    }

    function test_countdownItemGlassKeepsHoverBorder() {
        verify(Qt.colorEqual(countdownItem.color, Theme.glassCard))
        // hover 描边行为是既有交互（border → accent），底色玻璃化不得动它；
        // 默认态（无悬停）边框仍应是 Theme.border。
        verify(Qt.colorEqual(countdownItem.border.color, Theme.border))
    }
}
