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
}
