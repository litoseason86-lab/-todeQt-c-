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
        wallpaper.themeSource = Theme.backgroundThemes
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

    function test_supportedMotifsIsExactFixedList() {
        compare(wallpaper.supportedMotifs.length, 6)
        compare(wallpaper.supportedMotifs[0], "windowLight")
        compare(wallpaper.supportedMotifs[1], "sunsetPeaks")
        compare(wallpaper.supportedMotifs[2], "orchid")
        compare(wallpaper.supportedMotifs[3], "moonMist")
        compare(wallpaper.supportedMotifs[4], "fallingPetals")
        compare(wallpaper.supportedMotifs[5], "goldenWaves")
    }

    function test_everyThemeDispatchesToItsMotif() {
        var expected = {
            warmPaper: "windowLight",
            sunset: "sunsetPeaks",
            celadon: "orchid",
            mist: "moonMist",
            sakura: "fallingPetals",
            wheat: "goldenWaves"
        }

        wallpaper.themeSource = [
            { id: "invalid", name: "非法", motif: "unknownMotif", base: "#ffffff", blobs: [] }
        ]
        wallpaper.themeId = "invalid"
        tryVerify(function() { return wallpaper.lastPaintedMotif === "" }, 3000)

        wallpaper.themeSource = Theme.backgroundThemes
        for (var i = 0; i < Theme.backgroundThemes.length; i++) {
            var theme = Theme.backgroundThemes[i]
            wallpaper.themeSource = [
                { id: "invalid", name: "非法", motif: "unknownMotif", base: "#ffffff", blobs: [] }
            ]
            wallpaper.themeId = "invalid"
            tryVerify(function() { return wallpaper.lastPaintedMotif === "" }, 3000)
            var before = wallpaper.motifPaintCount

            wallpaper.themeSource = Theme.backgroundThemes
            wallpaper.themeId = theme.id
            tryVerify(function() {
                return wallpaper.lastPaintedMotif === expected[theme.id]
                    && wallpaper.motifPaintCount > before
            }, 3000)
        }
    }

    function test_unknownMotifSkipsDrawingButKeepsGradient() {
        wallpaper.themeSource = [
            { id: "custom", name: "自定义", motif: "noSuchMotif", base: "#ffffff", blobs: [] }
        ]
        wallpaper.themeId = "custom"
        tryVerify(function() { return wallpaper.paintCount > 0 }, 3000)
        var pc = wallpaper.paintCount
        var mpc = wallpaper.motifPaintCount

        wallpaper.themeId = "custom"
        wallpaper.forceRepaintForTest()

        tryVerify(function() { return wallpaper.paintCount > pc }, 3000)
        compare(wallpaper.lastPaintedMotif, "")
        compare(wallpaper.motifPaintCount, mpc)
    }
}
