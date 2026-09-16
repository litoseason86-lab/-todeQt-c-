import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

// 计时圆环：换主题要重绘，暂停只压暗盘面。
//
// Canvas 不会因为绑定里的颜色变了就自己重画——必须显式 requestPaint()，
// 否则换到夜间主题后圆环还留着日间的配色，直到下一次尺寸变化才「突然」修好。
TestCase {
    id: testCase
    name: "FocusRingTheme"
    when: windowShown
    visible: true
    width: 320
    height: 320

    FocusRing { id: ring; width: 200; height: 200; y: 60 }
    SignalSpy { id: painted; target: ring; signalName: "painted" }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    function test_themeChangeRepaintsRing() {
        Theme.activeThemeId = "warm"
        wait(50)
        painted.clear()
        Theme.activeThemeId = "starry"
        tryVerify(function() { return painted.count > 0 })
        Theme.activeThemeId = "warm"
    }

    function test_dimmedOnlyDarkensTheDialNotTheClockText() {
        ring.dimmed = true
        compare(ring.opacity, 1, "暂停不能压暗计时文字")
        compare(ring.drawingOpacity, 0.38)
    }
}
