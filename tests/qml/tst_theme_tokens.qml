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
        verify(Qt.colorEqual(Theme.dangerSoft, "#b37562"), "dangerSoft 取值不对")
    }

    function test_scaleTokens() {
        compare(Theme.fontMd, 13)
        compare(Theme.fontXxl, 24)
        compare(Theme.space16, 16)
        compare(Theme.radiusMd, 6)
    }

    function test_fontFamilyTokens() {
        compare(Theme.fontFamilyClock, "Space Grotesk")
        compare(Theme.fontFamilyData, "Bricolage Grotesque")
    }

    function test_chartColorsIsArray() {
        compare(Theme.chartColors.length, 6)
        // 顺带校验首元素值，确保数组不是被序列化成空串等异常形态。
        verify(Qt.colorEqual(Theme.chartColors[0], "#d4a574"), "chartColors[0] 取值不对")
    }

    function test_glassTokens() {
        verify(Qt.colorEqual(Theme.glassSidebar, Qt.rgba(1, 1, 252 / 255, 0.55)), "glassSidebar 取值不对")
        verify(Qt.colorEqual(Theme.glassCard, Qt.rgba(1, 1, 250 / 255, 0.68)), "glassCard 取值不对")
        verify(Qt.colorEqual(Theme.glassDialog, Qt.rgba(1, 254 / 255, 249 / 255, 0.94)), "glassDialog 取值不对")
        verify(Qt.colorEqual(Theme.glassBorder, Qt.rgba(1, 1, 1, 0.65)), "glassBorder 取值不对")
    }

    function test_backgroundThemesDefinitions() {
        var themes = Theme.backgroundThemes
        compare(themes.length, 6)
        compare(themes[0].id, "warmPaper")

        var seen = {}
        for (var i = 0; i < themes.length; i++) {
            var t = themes[i]
            verify(!seen[t.id], "id 重复: " + t.id)
            seen[t.id] = true
            verify(String(t.name).length > 0, t.id + " 缺名称")
            verify(String(t.motif).length > 0, t.id + " 缺图案标识")
            compare(String(t.base).charAt(0), "#")
            compare(t.blobs.length, 3)
            for (var j = 0; j < 3; j++) {
                var b = t.blobs[j]
                verify(b.cx >= 0 && b.cy >= 0, t.id + " 光晕坐标非法")
                verify(b.rx > 0 && b.ry > 0, t.id + " 光晕半径非法")
                compare(String(b.color).charAt(0), "#")
            }
        }
    }

    function test_backgroundThemesMotifMapping() {
        var expected = {
            warmPaper: "windowLight",
            sunset: "sunsetPeaks",
            celadon: "orchid",
            mist: "moonMist",
            sakura: "fallingPetals",
            wheat: "goldenWaves"
        }
        var themes = Theme.backgroundThemes

        for (var i = 0; i < themes.length; i++) {
            var theme = themes[i]
            compare(theme.motif, expected[theme.id], theme.id + " 图案映射错误")
        }
    }
}
