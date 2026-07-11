import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "BackgroundWallpaper"
    when: windowShown
    width: 400
    height: 300

    BackgroundWallpaper {
        id: wallpaper

        width: 400
        height: 300
    }

    function init() {
        wallpaper.themeId = "warm"
        wallpaper.themeSource = Theme.themes
    }

    function test_defaultResolvesWarm() {
        compare(wallpaper.resolvedTheme.id, "warm")
    }

    function test_everyThemeResolvesItsWallpaper() {
        for (var i = 0; i < Theme.themes.length; i++) {
            var t = Theme.themes[i]
            wallpaper.themeId = t.id
            compare(wallpaper.resolvedTheme.id, t.id)
            var url = String(wallpaper.resolvedTheme.wallpaper)
            verify(url.indexOf("resources/wallpapers/" + t.id + ".png") >= 0,
                   t.id + " 壁纸 URL 不对: " + url)
        }
    }

    function test_unknownIdFallsBackToWarm() {
        wallpaper.themeId = "no-such-theme"
        compare(wallpaper.resolvedTheme.id, "warm")
    }

    function test_legacyIdsResolveToMigratedTheme() {
        var mapping = { warmPaper: "warm", sunset: "warm", wheat: "warm",
                        celadon: "jiangnan", mist: "jiangnan", sakura: "pink" }
        for (var legacy in mapping) {
            wallpaper.themeId = legacy
            compare(wallpaper.resolvedTheme.id, mapping[legacy],
                    legacy + " 应迁移到 " + mapping[legacy])
        }
    }

    function test_wallpaperImageLoads() {
        // qmltestrunner 下 Qt.resolvedUrl 落到源码树真实文件，Image 应能加载成功。
        var image = findChild(wallpaper, "wallpaperImage")
        verify(image !== null, "缺 wallpaperImage 子项")
        wallpaper.themeId = "pink"
        tryVerify(function() { return image.status === Image.Ready }, 5000)
    }

    function test_baseFallbackRectMatchesTheme() {
        wallpaper.themeId = "moon"
        var baseRect = findChild(wallpaper, "wallpaperBase")
        verify(baseRect !== null, "缺 wallpaperBase 兜底层")
        verify(Qt.colorEqual(baseRect.color, wallpaper.resolvedTheme.base),
               "兜底色应取主题 base")
    }

    function test_injectedThemeSourceWithoutWallpaperShowsBaseOnly() {
        wallpaper.themeSource = [
            { id: "custom", name: "自定义", mode: "light", base: "#ffffff", wallpaper: "" }
        ]
        wallpaper.themeId = "custom"
        compare(wallpaper.resolvedTheme.id, "custom")
        var image = findChild(wallpaper, "wallpaperImage")
        compare(String(image.source), "")
    }

    function test_scrimMatchesThemeToken() {
        wallpaper.themeId = "pink"
        var scrim = findChild(wallpaper, "wallpaperScrim")
        verify(scrim !== null, "缺 wallpaperScrim 罩层")
        verify(Qt.colorEqual(scrim.color, wallpaper.resolvedTheme.wallpaperScrim),
               "罩层颜色应取主题 wallpaperScrim")
    }

    function test_scrimTransparentWhenDisabled() {
        wallpaper.themeId = "pink"
        wallpaper.scrimEnabled = false
        var scrim = findChild(wallpaper, "wallpaperScrim")
        verify(Qt.colorEqual(scrim.color, "transparent"),
               "scrimEnabled=false 时罩层应全透明")
        wallpaper.scrimEnabled = true
    }

    function test_scrimTransparentWhenThemeOmitsToken() {
        wallpaper.themeSource = [
            { id: "custom", name: "自定义", mode: "light", base: "#ffffff", wallpaper: "" }
        ]
        wallpaper.themeId = "custom"
        var scrim = findChild(wallpaper, "wallpaperScrim")
        verify(Qt.colorEqual(scrim.color, "transparent"),
               "无 wallpaperScrim 的主题罩层应全透明")
    }
}
