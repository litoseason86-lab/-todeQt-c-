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
        wallpaper.themeId = "warmPaper"
    }

    function collectChildren(item, result) {
        if (!item || !item.children) {
            return result
        }

        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i]
            result.push(child)
            collectChildren(child, result)
        }
        return result
    }

    function test_defaultResolvesWarmPaper() {
        compare(wallpaper.themeId, "warmPaper")
        compare(wallpaper.resolvedTheme.id, "warmPaper")
    }

    function test_validIdResolves() {
        wallpaper.themeId = "celadon"
        compare(wallpaper.resolvedTheme.id, "celadon")
    }

    function test_unknownIdFallsBackToWarmPaper() {
        wallpaper.themeId = "no-such-theme"
        compare(wallpaper.resolvedTheme.id, "warmPaper")
    }

    function test_themeChangeTriggersRepaint() {
        tryVerify(function() { return wallpaper.paintCount > 0 }, 3000)
        var before = wallpaper.paintCount
        wallpaper.themeId = "sunset"
        tryVerify(function() { return wallpaper.paintCount > before }, 3000)
    }

    function test_noTiledNoiseTextureLayer() {
        var children = collectChildren(wallpaper, [])
        for (var i = 0; i < children.length; ++i) {
            var item = children[i]
            if (item.fillMode === Image.Tile && String(item.source).indexOf("feTurbulence") >= 0) {
                fail("SVG 噪点瓦片会在浅色壁纸上形成柱状拼接块，应移除")
            }
        }
    }
}
