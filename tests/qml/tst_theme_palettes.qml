import QtQuick
import QtTest
import "../../qml"

// 主题系统 v2：六主题定义完整性、旧 id 迁移、palette 随 activeThemeId 切换。
TestCase {
    name: "ThemePalettes"

    function init() {
        Theme.activeThemeId = "warm"
    }

    function test_themesLineup() {
        var expected = ["warm", "pink", "jiangnan", "starry", "rainy", "moon"]
        compare(Theme.themes.length, 6)
        for (var i = 0; i < expected.length; i++) {
            compare(Theme.themes[i].id, expected[i])
        }
    }

    function test_modes() {
        var modes = { warm: "light", pink: "light", jiangnan: "light",
                      starry: "dark", rainy: "dark", moon: "dark" }
        for (var i = 0; i < Theme.themes.length; i++) {
            var t = Theme.themes[i]
            compare(t.mode, modes[t.id])
        }
    }

    function test_everyThemeHasFullTokenSet() {
        var keys = ["name", "base", "wallpaper",
            "surface", "surfaceRaised", "surfaceSunken",
            "border", "borderSubtle",
            "inkStrong", "ink", "inkSoft", "inkMuted",
            "accent", "accentStrong", "accentSoft", "accentInk",
            "success", "danger", "dangerBorder", "dangerSoft",
            "chartColors",
            "focusRingArcStart", "focusRingArcMid", "focusRingArcEnd", "focusRingTrack",
            "focusGlassCenter", "focusGlassEdge", "focusGlassShadow",
            "focusGlassHighlight", "focusColonMuted",
            "glassSidebar", "glassCard", "glassDialog", "glassBorder", "wallpaperScrim"]
        for (var i = 0; i < Theme.themes.length; i++) {
            var t = Theme.themes[i]
            for (var k = 0; k < keys.length; k++) {
                verify(t[keys[k]] !== undefined, t.id + " 缺 token: " + keys[k])
            }
            compare(t.chartColors.length, 6, t.id + " chartColors 应为 6 色")
        }
    }

    function test_wallpaperUrls() {
        for (var i = 0; i < Theme.themes.length; i++) {
            var t = Theme.themes[i]
            var url = String(t.wallpaper)
            verify(url.indexOf("resources/wallpapers/" + t.id + ".png") >= 0,
                   t.id + " 壁纸 URL 不对: " + url)
        }
    }

    function test_legacyIdMigration() {
        compare(Theme.migrateThemeId("warmPaper"), "warm")
        compare(Theme.migrateThemeId("sunset"), "warm")
        compare(Theme.migrateThemeId("wheat"), "warm")
        compare(Theme.migrateThemeId("celadon"), "jiangnan")
        compare(Theme.migrateThemeId("mist"), "jiangnan")
        compare(Theme.migrateThemeId("sakura"), "pink")
        compare(Theme.migrateThemeId("pink"), "pink")
        compare(Theme.migrateThemeId("no-such"), "no-such")
    }

    function test_resolveFallsBackToWarm() {
        compare(Theme.resolveTheme("no-such-theme").id, "warm")
        compare(Theme.resolveTheme("celadon").id, "jiangnan")
    }

    function test_paletteFollowsActiveThemeId() {
        compare(Theme.palette.id, "warm")
        Theme.activeThemeId = "starry"
        compare(Theme.palette.id, "starry")
        compare(Theme.palette.mode, "dark")
    }

    function test_displayCategoryColorMapsLegacyPalette() {
        compare(Theme.displayCategoryColor("#d4a574"), "#e8b04e")
        compare(Theme.displayCategoryColor("#D4A574"), "#e8b04e")
        compare(Theme.displayCategoryColor("#58352c"), "#8a94a6")
        compare(Theme.displayCategoryColor("#e5638f"), "#e5638f")
        compare(Theme.displayCategoryColor("#123456"), "#123456")
    }
}
