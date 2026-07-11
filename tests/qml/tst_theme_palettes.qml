import QtQuick
import QtTest
import "../../qml"

// 壁纸主题元数据：六款阵容、壁纸 URL、旧 id 迁移。UI 色值不随主题（见 tst_theme_tokens）。
TestCase {
    name: "ThemePalettes"

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

    function test_everyThemeHasWallpaperMetadata() {
        var keys = ["name", "mode", "base", "wallpaper"]
        for (var i = 0; i < Theme.themes.length; i++) {
            var t = Theme.themes[i]
            for (var k = 0; k < keys.length; k++) {
                verify(t[keys[k]] !== undefined, t.id + " 缺字段: " + keys[k])
            }
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
}
