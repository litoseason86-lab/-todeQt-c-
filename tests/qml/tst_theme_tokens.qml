import QtQuick
import QtTest
import "../../qml"

// 验证 Theme 单例可被解析（注册生效），且核心令牌取值正确。
// UI 色值固定为暖纸主题，不随壁纸切换。
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
        verify(Qt.colorEqual(Theme.glassCard, Qt.rgba(1, 1, 250 / 255, 0.42)), "glassCard 取值不对")
        verify(Qt.colorEqual(Theme.glassHover, Qt.rgba(1, 1, 250 / 255, 0.62)), "glassHover 取值不对")
        verify(Qt.colorEqual(Theme.glassDialog, Qt.rgba(1, 254 / 255, 249 / 255, 0.985)), "glassDialog 取值不对")
        verify(Qt.colorEqual(Theme.glassBorder, Qt.rgba(1, 1, 1, 0.65)), "glassBorder 取值不对")
    }

    function test_focusRingTokens() {
        verify(Qt.colorEqual(Theme.focusRingArcStart, "#f1bd7e"), "focusRingArcStart 取值不对")
        verify(Qt.colorEqual(Theme.focusRingArcMid, "#f4d3ab"), "focusRingArcMid 取值不对")
        verify(Qt.colorEqual(Theme.focusRingArcEnd, "#f4c3bd"), "focusRingArcEnd 取值不对")
        verify(Qt.colorEqual(Theme.focusRingTrack, "#faf1e8"), "focusRingTrack 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassCenter, "#fffefb"), "focusGlassCenter 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassEdge, "#fdf3ee"), "focusGlassEdge 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassShadow, "#e2b9a6"), "focusGlassShadow 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassHighlight, "#ffffff"), "focusGlassHighlight 取值不对")
        verify(Qt.colorEqual(Theme.focusColonMuted, "#e8bda6"), "focusColonMuted 取值不对")
    }

    function test_focusBreakAccentIsChartColor3() {
        verify(Qt.colorEqual(Theme.focusBreakAccent, Theme.chartColors[3]))
    }
}
