import QtQuick
import QtTest
import "../../qml"

// 验证 Theme 单例可被解析（注册生效），且核心令牌取值正确。
TestCase {
    name: "ThemeTokens"

    function test_colorTokens() {
        verify(Qt.colorEqual(Theme.accent, "#d4a574"), "accent 取值不对")
        verify(Qt.colorEqual(Theme.accentStrong, "#c99666"), "accentStrong 取值不对")
        verify(Qt.colorEqual(Theme.surface, "#fffef9"), "surface 取值不对")
        verify(Qt.colorEqual(Theme.border, "#e8dfc8"), "border 取值不对")
        verify(Qt.colorEqual(Theme.ink, "#5d4e37"), "ink 取值不对")
        verify(Qt.colorEqual(Theme.danger, "#b24f3d"), "danger 取值不对")
    }

    function test_scaleTokens() {
        compare(Theme.fontMd, 13)
        compare(Theme.fontXxl, 24)
        compare(Theme.space16, 16)
        compare(Theme.radiusMd, 6)
    }

    function test_chartColorsIsArray() {
        compare(Theme.chartColors.length, 6)
        // 顺带校验首元素值，确保数组不是被序列化成空串等异常形态。
        verify(Qt.colorEqual(Theme.chartColors[0], "#d4a574"), "chartColors[0] 取值不对")
    }
}
