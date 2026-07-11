import QtQuick
import QtTest
import "../../qml"

// 验证 Theme 单例 token 绑定当前主题色板，且随 activeThemeId 切换。
TestCase {
    name: "ThemeTokens"

    function init() {
        Theme.activeThemeId = "warm"
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    function test_defaultWarmTokens() {
        verify(Qt.colorEqual(Theme.accent, "#dc9550"), "accent 取值不对")
        verify(Qt.colorEqual(Theme.accentStrong, "#c98240"), "accentStrong 取值不对")
        verify(Qt.colorEqual(Theme.surface, "#fffdf6"), "surface 取值不对")
        verify(Qt.colorEqual(Theme.border, "#ead9bd"), "border 取值不对")
        verify(Qt.colorEqual(Theme.ink, "#6b573d"), "ink 取值不对")
        verify(Qt.colorEqual(Theme.danger, "#b24f3d"), "danger 取值不对")
        verify(Qt.colorEqual(Theme.dangerSoft, "#b37562"), "dangerSoft 取值不对")
        verify(Qt.colorEqual(Theme.shadow, "#000000"), "shadow 应保持纯黑")
    }

    function test_tokensFollowThemeSwitch() {
        Theme.activeThemeId = "starry"
        verify(Qt.colorEqual(Theme.accent, "#8f7ff0"), "starry accent 未生效")
        verify(Qt.colorEqual(Theme.inkStrong, "#eceafb"), "starry inkStrong 未生效")
        verify(Qt.colorEqual(Theme.surface, "#1b1936"), "starry surface 未生效")
        verify(Qt.colorEqual(Theme.success, "#6fcf73"), "暗色 success 应提亮")
        Theme.activeThemeId = "warm"
        verify(Qt.colorEqual(Theme.accent, "#dc9550"), "切回 warm 未复原")
    }

    function test_glassTokensFollowTheme() {
        verify(Qt.colorEqual(Theme.glassSidebar, Qt.rgba(1, 250 / 255, 242 / 255, 0.55)),
               "warm glassSidebar 取值不对")
        Theme.activeThemeId = "moon"
        verify(Qt.colorEqual(Theme.glassCard, Qt.rgba(20 / 255, 32 / 255, 50 / 255, 0.62)),
               "moon glassCard 取值不对")
        verify(Qt.colorEqual(Theme.glassBorder, Qt.rgba(1, 1, 1, 0.14)),
               "暗色 glassBorder 取值不对")
    }

    function test_chartColorsFollowTheme() {
        compare(Theme.chartColors.length, 6)
        verify(Qt.colorEqual(Theme.chartColors[0], "#dc9550"), "warm chartColors[0] 不对")
        Theme.activeThemeId = "rainy"
        verify(Qt.colorEqual(Theme.chartColors[0], "#e8a34e"), "rainy chartColors[0] 不对")
    }

    function test_focusBreakAccentIsChartColor3() {
        verify(Qt.colorEqual(Theme.focusBreakAccent, Theme.chartColors[3]))
        Theme.activeThemeId = "starry"
        verify(Qt.colorEqual(Theme.focusBreakAccent, Theme.chartColors[3]))
    }

    function test_focusRingTokensFollowTheme() {
        verify(Qt.colorEqual(Theme.focusRingArcStart, "#f1bd7e"), "warm arcStart 不对")
        Theme.activeThemeId = "moon"
        verify(Qt.colorEqual(Theme.focusRingArcStart, "#8fb4de"), "moon arcStart 不对")
        verify(Qt.colorEqual(Theme.focusRingTrack, "#223349"), "moon track 不对")
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
}
