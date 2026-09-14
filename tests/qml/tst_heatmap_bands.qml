import QtQuick
import QtTest
import "../../qml"
import "../../qml/HeatmapBands.js" as HeatmapBands

// 热力取档函数与热力令牌。
//
// 令牌部分断言的是**判据**而不只是色值：配色能不能用看对比度与色差，不看亮度差
// （0.299R + 0.587G + 0.114B 只说明明度拉开了，回答不了「相邻两档分不分得出」）。
// 判据写死在这里，下一次调色若悄悄退回「看起来差不多」的色阶，这些用例会先红。
TestCase {
    name: "HeatmapBands"

    function init() {
        Theme.activeThemeId = "warm"
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    // —— CIEDE2000（sRGB → Lab，D65）——
    function srgbToLinear(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
    }

    function toLab(color) {
        var c = Qt.color(color)
        var r = srgbToLinear(c.r), g = srgbToLinear(c.g), b = srgbToLinear(c.b)
        var x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
        var y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        var z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883
        function f(t) { return t > 216 / 24389 ? Math.cbrt(t) : (841 / 108) * t + 4 / 29 }
        return { L: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)) }
    }

    function deltaE00(c1, c2) {
        var p = toLab(c1), q = toLab(c2)
        var rad = Math.PI / 180
        var C1 = Math.hypot(p.a, p.b), C2 = Math.hypot(q.a, q.b)
        var Cb = (C1 + C2) / 2
        var G = 0.5 * (1 - Math.sqrt(Math.pow(Cb, 7) / (Math.pow(Cb, 7) + Math.pow(25, 7))))
        var a1 = (1 + G) * p.a, a2 = (1 + G) * q.a
        var C1p = Math.hypot(a1, p.b), C2p = Math.hypot(a2, q.b)
        var h1 = (Math.atan2(p.b, a1) / rad + 360) % 360
        var h2 = (Math.atan2(q.b, a2) / rad + 360) % 360
        var dL = q.L - p.L, dC = C2p - C1p
        var dh = 0
        if (C1p * C2p !== 0)
            dh = Math.abs(h2 - h1) <= 180 ? h2 - h1 : (h2 > h1 ? h2 - h1 - 360 : h2 - h1 + 360)
        var dH = 2 * Math.sqrt(C1p * C2p) * Math.sin(dh * rad / 2)
        var Lb = (p.L + q.L) / 2, Cbp = (C1p + C2p) / 2
        var hb = h1 + h2
        if (C1p * C2p !== 0)
            hb = Math.abs(h1 - h2) <= 180 ? (h1 + h2) / 2 : (h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2)
        var T = 1 - 0.17 * Math.cos((hb - 30) * rad) + 0.24 * Math.cos(2 * hb * rad)
                + 0.32 * Math.cos((3 * hb + 6) * rad) - 0.20 * Math.cos((4 * hb - 63) * rad)
        var dTheta = 30 * Math.exp(-Math.pow((hb - 275) / 25, 2))
        var Rc = 2 * Math.sqrt(Math.pow(Cbp, 7) / (Math.pow(Cbp, 7) + Math.pow(25, 7)))
        var Sl = 1 + (0.015 * Math.pow(Lb - 50, 2)) / Math.sqrt(20 + Math.pow(Lb - 50, 2))
        var Sc = 1 + 0.045 * Cbp
        var Sh = 1 + 0.015 * Cbp * T
        var Rt = -Math.sin(2 * dTheta * rad) * Rc
        return Math.sqrt(Math.pow(dL / Sl, 2) + Math.pow(dC / Sc, 2) + Math.pow(dH / Sh, 2)
                         + Rt * (dC / Sc) * (dH / Sh))
    }

    function test_deltaE00MatchesTheReviewMeasurements() {
        // 下面几组参照值出自 2026-09-14 热力色阶定稿评审时另写的一份 Python 实现。
        // 两份独立实现对得上，才能说这里的断言和评审时看的是同一把尺子。
        fuzzyCompare(deltaE00("#f1d9c4", "#e1a161"), 17.8779, 0.001)
        fuzzyCompare(deltaE00("#d9d0c7", "#f0e6d2"), 6.6907, 0.001)
        fuzzyCompare(deltaE00("#544c45", "#4a3d2b"), 7.3775, 0.001)
        fuzzyCompare(deltaE00("#000000", "#ffffff"), 100.0, 0.001)
        compare(deltaE00("#855d36", "#855d36"), 0)
    }

    // —— 取档函数 ——

    function test_zeroAndInvalidValuesAreNoInvestment() {
        compare(HeatmapBands.bandForMinutes(0), HeatmapBands.NONE)
        compare(HeatmapBands.bandForMinutes(-5), HeatmapBands.NONE)
        compare(HeatmapBands.bandForMinutes(null), HeatmapBands.NONE)
        compare(HeatmapBands.bandForMinutes(undefined), HeatmapBands.NONE)
        compare(HeatmapBands.bandForMinutes("不是数字"), HeatmapBands.NONE)
        // NaN 与任何数比较都是假：写成 `minutes <= 0` 的实现会让它一路漏到最深那档。
        compare(HeatmapBands.bandForMinutes(NaN), HeatmapBands.NONE)
    }

    function test_thresholdBoundaries() {
        compare(HeatmapBands.bandForMinutes(0.5), 0)      // 30 秒也是有投入
        compare(HeatmapBands.bandForMinutes(59), 0)
        compare(HeatmapBands.bandForMinutes(3599 / 60), 0)
        compare(HeatmapBands.bandForMinutes(60), 1)
        compare(HeatmapBands.bandForMinutes(149), 1)
        compare(HeatmapBands.bandForMinutes(150), 2)
        compare(HeatmapBands.bandForMinutes(299), 2)
        compare(HeatmapBands.bandForMinutes(300), 3)
        compare(HeatmapBands.bandForMinutes(24 * 60), 3)
    }

    function test_bandCountMatchesThresholds() {
        compare(HeatmapBands.BAND_COUNT, HeatmapBands.THRESHOLDS.length + 1)
    }

    // —— 令牌 ——

    function checkPalette(expectedBands, expectedTrack) {
        compare(Theme.heatmapBandColors.length, HeatmapBands.BAND_COUNT)
        for (var i = 0; i < expectedBands.length; ++i)
            verify(Qt.colorEqual(Theme.heatmapBandColors[i], expectedBands[i]),
                   "第 " + (i + 1) + " 档取值不对：" + Theme.heatmapBandColors[i])
        verify(Qt.colorEqual(Theme.heatmapEmptyTrack, expectedTrack),
               "heatmapEmptyTrack 取值不对：" + Theme.heatmapEmptyTrack)
    }

    function test_lightPaletteIsTheSignedOffValues() {
        checkPalette(["#f1d9c4", "#e1a161", "#855d36", "#52381e"], "#d9d0c7")
    }

    function test_darkPaletteIsTheSignedOffValues() {
        Theme.activeThemeId = "starry"
        verify(Theme.darkMode)
        checkPalette(["#5e4123", "#825b34", "#d09459", "#edccaf"], "#544c45")
    }

    function checkAdjacentBandsAreDistinguishable() {
        for (var i = 1; i < Theme.heatmapBandColors.length; ++i) {
            var d = deltaE00(Theme.heatmapBandColors[i - 1], Theme.heatmapBandColors[i])
            verify(d >= 7, "第 " + i + "→" + (i + 1) + " 档 ΔE00 只有 " + d.toFixed(1) + "，低于 7")
        }
    }

    function test_adjacentBandsAreDistinguishableLight() {
        checkAdjacentBandsAreDistinguishable()
    }

    function test_adjacentBandsAreDistinguishableDark() {
        Theme.activeThemeId = "starry"
        checkAdjacentBandsAreDistinguishable()
    }

    // 空轨道要在月历格子会出现的每一种底色上都看得见——尤其是选中底 accentSoft：
    // 看不见时「选中 × 零投入」会被读成「选中 × 未来」（未来不画条），而未来日同样能点选。
    function checkEmptyTrackOnEveryCellGround() {
        var grounds = [
            { name: "普通 surfaceRaised", color: Theme.surfaceRaised },
            { name: "选中 accentSoft", color: Theme.accentSoft },
            { name: "悬停 surface", color: Theme.surface }
        ]
        for (var i = 0; i < grounds.length; ++i) {
            var d = deltaE00(Theme.heatmapEmptyTrack, grounds[i].color)
            verify(d >= 5, "空轨道在" + grounds[i].name + "上 ΔE00 只有 " + d.toFixed(1) + "，低于 5")
        }
        var fromFirstBand = deltaE00(Theme.heatmapEmptyTrack, Theme.heatmapBandColors[0])
        verify(fromFirstBand >= 5, "空轨道与第 1 档 ΔE00 只有 " + fromFirstBand.toFixed(1))
        // 零投入不能比任何有效投入显眼：普通底上空轨道必须比第 1 档安静。
        var trackWeight = deltaE00(Theme.heatmapEmptyTrack, Theme.surfaceRaised)
        var firstBandWeight = deltaE00(Theme.heatmapBandColors[0], Theme.surfaceRaised)
        verify(trackWeight < firstBandWeight,
               "空轨道（" + trackWeight.toFixed(1) + "）比第 1 档（" + firstBandWeight.toFixed(1) + "）还显眼")
    }

    function test_emptyTrackIsVisibleOnEveryCellGroundLight() {
        checkEmptyTrackOnEveryCellGround()
    }

    function test_emptyTrackIsVisibleOnEveryCellGroundDark() {
        Theme.activeThemeId = "starry"
        checkEmptyTrackOnEveryCellGround()
    }

    // —— 目标详情热力图（阶段五）——
    // 那张图把色阶铺满整格，日期数字就压在底色上，每档要有自己的字色。

    function test_lightBandInkIsTheSignedOffValues() {
        compare(Theme.heatmapBandInkColors.length, HeatmapBands.BAND_COUNT)
        var expected = ["#3d3327", "#3d3327", "#fffef9", "#fffef9"]
        for (var i = 0; i < expected.length; ++i)
            verify(Qt.colorEqual(Theme.heatmapBandInkColors[i], expected[i]),
                   "第 " + (i + 1) + " 档字色不对：" + Theme.heatmapBandInkColors[i])
    }

    function test_darkBandInkIsTheSignedOffValues() {
        Theme.activeThemeId = "starry"
        compare(Theme.heatmapBandInkColors.length, HeatmapBands.BAND_COUNT)
        var expected = ["#f3ead9", "#f3ead9", "#2a241c", "#2a241c"]
        for (var i = 0; i < expected.length; ++i)
            verify(Qt.colorEqual(Theme.heatmapBandInkColors[i], expected[i]),
                   "第 " + (i + 1) + " 档字色不对：" + Theme.heatmapBandInkColors[i])
    }

    function checkBandInkContrast() {
        for (var i = 0; i < HeatmapBands.BAND_COUNT; ++i) {
            var ratio = Theme.contrastRatio(Theme.heatmapBandInkColors[i], Theme.heatmapBandColors[i])
            verify(ratio >= 4.5, "第 " + (i + 1) + " 档文字对比度只有 " + ratio.toFixed(2) + ":1")
        }
    }

    function test_bandInkMeetsTextContrastLight() {
        checkBandInkContrast()
    }

    function test_bandInkMeetsTextContrastDark() {
        Theme.activeThemeId = "starry"
        checkBandInkContrast()
    }

    // 「学了一点」和「完全没学」看起来一样，比档位少更严重，所以单列，不混在相邻档遍历里。
    function checkZeroFillIsDistinguishableFromFirstBand() {
        var d = deltaE00(Theme.surfaceSunken, Theme.heatmapBandColors[0])
        verify(d >= 7, "零值底色与第 1 档 ΔE00 只有 " + d.toFixed(1) + "，低于 7")
    }

    function test_zeroFillIsDistinguishableFromFirstBandLight() {
        checkZeroFillIsDistinguishableFromFirstBand()
    }

    function test_zeroFillIsDistinguishableFromFirstBandDark() {
        Theme.activeThemeId = "starry"
        checkZeroFillIsDistinguishableFromFirstBand()
    }

    // 零投入与未来格的日期沿用 Theme.ink，不降成 inkMuted：
    // inkMuted 在零值底上日间只有 2.88:1、在页面底上 3.31:1，读不出来。
    function checkNonBandDateInkContrast() {
        var grounds = [
            { name: "零值底 surfaceSunken", color: Theme.surfaceSunken },
            { name: "页面底 surface", color: Theme.surface },
            { name: "卡片底 surfaceRaised", color: Theme.surfaceRaised }
        ]
        for (var i = 0; i < grounds.length; ++i) {
            var ratio = Theme.contrastRatio(Theme.ink, grounds[i].color)
            verify(ratio >= 4.5, "日期在" + grounds[i].name + "上只有 " + ratio.toFixed(2) + ":1")
        }
    }

    function test_nonBandDateInkContrastLight() {
        checkNonBandDateInkContrast()
    }

    function test_nonBandDateInkContrastDark() {
        Theme.activeThemeId = "starry"
        checkNonBandDateInkContrast()
    }

    function test_bandsOrderFollowsThemeDirection() {
        // 浅底投入越多越深，深底投入越多越亮。直接把日间色阶搬到深底，最低档会是近白块。
        var light = Theme.heatmapBandColors
        verify(Theme.contrastRatio(light[0], "#ffffff") < Theme.contrastRatio(light[3], "#ffffff"))
        Theme.activeThemeId = "starry"
        var dark = Theme.heatmapBandColors
        verify(Theme.contrastRatio(dark[0], "#ffffff") > Theme.contrastRatio(dark[3], "#ffffff"))
    }
}
