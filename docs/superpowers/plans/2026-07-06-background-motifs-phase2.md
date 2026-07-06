# 背景壁纸二阶段（专属图案精美化）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给六张壁纸各加一个 Canvas 手绘专属图案（窗光/落日远山/兰草/月雾/落樱/金浪），把"生成的渐变"升级为"设计过的壁纸"，零图片资产、任意分辨率锐利。

**Architecture:** `Theme.backgroundThemes` 每项加 `motif` 字段；`BackgroundWallpaper` 的 `onPaint` 在"底色+光晕"之后按 `resolvedMotif` 用 `switch` 分发到六个 `paintXxx(ctx)`。分发信号靠 `lastPaintedMotif`/`motifPaintCount` 驱动属性（函数末行赋值证明执行到底）；未知 motif 走 default（清空 `lastPaintedMotif`、不计数、只保留渐变）。绘制统一在 `ctx.scale(width/100, height/62)` 缩放坐标系里按设计稿数值落笔。

**Tech Stack:** Qt 6.9 / QML Canvas 2D / qmltestrunner

**Depends on:** 一阶段已在本分支落地（`BackgroundWallpaper` 组件、`Theme.backgroundThemes`、`tst_background_wallpaper.qml` 均已存在）。

## Global Constraints

- 注释、提交说明一律中文；注释解释"为什么/边界"（AGENTS.md）。
- 构建：`cmake --build build`；**不得改 build/**。QML 单文件：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`；验收 = 连续 2 次全绿。
- qmllint 零警告：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/BackgroundWallpaper.qml`。
- QML 测试纪律：不断言 `visible === true`；浮点/alpha 用近似断言，不做像素抓取。
- **主题 id ↔ motif 映射（固定）**：warmPaper→windowLight、sunset→sunsetPeaks、celadon→orchid、mist→moonMist、sakura→fallingPetals、wheat→goldenWaves。
- **绘制坐标系**：设计稿 100×62 比例坐标；paintMotif 内一次 `ctx.scale(width/100, height/62)`，各 `paintXxx` 直接用设计稿数值。线宽**不做最小值 clamp**。
- **叙事元素 α ≤ 0.45 硬约束**（下方所有非柔光元素均满足）；柔光元素（径向淡出的光斑/日月晕/粉晕）不设上限、靠边角布局保证不干扰。
- **自动测试只验证"分发发生"，不验证"图案画对"**：每个 motif 批次必须做真机视觉验收，不得用 `lastPaintedMotif` 测试冒充图案质量验收。

---

## 批次一（数据 + 分发骨架）

### Task 1: Theme.backgroundThemes 增加 motif 字段

**Files:**

- Modify: `qml/Theme.qml`
- Test: `tests/qml/tst_theme_tokens.qml`

**Interfaces:**

- Produces: 六个主题各含 `motif` 字符串字段（值见映射表）。

- [ ] **Step 1: 写失败测试**

在 `tests/qml/tst_theme_tokens.qml` 的 `test_backgroundThemesDefinitions()` 内层循环里，`compare(String(b.color).charAt(0), "#")` 那段之后、内层 for 之外补一行 motif 校验。定位到该函数里 `verify(String(t.name).length > 0, ...)` 之后加：

```qml
            verify(String(t.motif).length > 0, t.id + " 缺 motif 字段")
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`
Expected: FAIL（`motif` undefined）。

- [ ] **Step 3: 实现——给六个主题各加 motif**

`qml/Theme.qml` 的 `backgroundThemes` 数组，给每项在 `base` 之后插 `motif`：

```qml
    readonly property var backgroundThemes: [
        { id: "warmPaper", name: "暖纸", base: "#faf2e4", motif: "windowLight", blobs: [
            { cx: 0.18, cy: 0.15, rx: 0.90, ry: 0.70, color: "#fdf3e0" },
            { cx: 0.85, cy: 0.25, rx: 0.80, ry: 0.60, color: "#f6e2c8" },
            { cx: 0.55, cy: 0.95, rx: 1.00, ry: 0.80, color: "#f2ded2" } ] },
        { id: "sunset", name: "暮橙", base: "#fdeadb", motif: "sunsetPeaks", blobs: [
            { cx: 0.15, cy: 0.10, rx: 0.85, ry: 0.70, color: "#ffe3c2" },
            { cx: 0.88, cy: 0.30, rx: 0.90, ry: 0.65, color: "#fbc9ad" },
            { cx: 0.50, cy: 1.00, rx: 1.10, ry: 0.75, color: "#f9d5c4" } ] },
        { id: "celadon", name: "青瓷", base: "#edf5ee", motif: "orchid", blobs: [
            { cx: 0.20, cy: 0.12, rx: 0.85, ry: 0.65, color: "#ddefe2" },
            { cx: 0.85, cy: 0.35, rx: 0.80, ry: 0.70, color: "#cde7dd" },
            { cx: 0.45, cy: 1.00, rx: 1.00, ry: 0.80, color: "#e3f1e4" } ] },
        { id: "mist", name: "晨雾", base: "#f0eff7", motif: "moonMist", blobs: [
            { cx: 0.18, cy: 0.15, rx: 0.85, ry: 0.65, color: "#e4e4f4" },
            { cx: 0.85, cy: 0.28, rx: 0.85, ry: 0.70, color: "#d7e2f3" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#ebe4f2" } ] },
        { id: "sakura", name: "樱粉", base: "#fdf0f1", motif: "fallingPetals", blobs: [
            { cx: 0.20, cy: 0.12, rx: 0.85, ry: 0.65, color: "#fbdbe2" },
            { cx: 0.85, cy: 0.30, rx: 0.85, ry: 0.70, color: "#f8e2ea" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#fceaea" } ] },
        { id: "wheat", name: "麦浪", base: "#fbf5e2", motif: "goldenWaves", blobs: [
            { cx: 0.18, cy: 0.12, rx: 0.85, ry: 0.65, color: "#f8edc6" },
            { cx: 0.85, cy: 0.32, rx: 0.85, ry: 0.70, color: "#f3e3b4" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#f9f0d2" } ] }
    ]
```

- [ ] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`（×2）
Expected: 全绿 ×2。

- [ ] **Step 5: 提交**

```bash
git add qml/Theme.qml tests/qml/tst_theme_tokens.qml
git commit -m "Theme 六主题各标注 motif 字段"
```

---

### Task 2: BackgroundWallpaper 分发骨架 + 全部驱动属性测试

**Files:**

- Modify: `qml/components/BackgroundWallpaper.qml`
- Test: `tests/qml/tst_background_wallpaper.qml`

**Interfaces:**

- Consumes: Task 1 的 `motif` 字段。
- Produces: root 上 `themeSource`（默认 `Theme.backgroundThemes`）、`resolvedMotif`、`supportedMotifs`、`lastPaintedMotif`（alias）、`motifPaintCount`（alias）；canvas 内六个 `paintXxx(ctx)`（本批次仅末行赋值，无绘制）与 `paintMotif(ctx)` 分发。

- [ ] **Step 1: 写失败测试**

在 `tests/qml/tst_background_wallpaper.qml` 的 `init()` 里，把重置扩展为同时复位数据源（防跨用例污染）：

```qml
    function init() {
        wallpaper.themeSource = Theme.backgroundThemes
        wallpaper.themeId = "warmPaper"
    }
```

在文件末尾 `test_noTiledNoiseTextureLayer()` 之后加：

```qml
    function test_resolvedMotifForCeladonIsOrchid() {
        wallpaper.themeId = "celadon"
        compare(wallpaper.resolvedMotif, "orchid")
    }

    function test_unknownThemeResolvesWindowLightMotif() {
        wallpaper.themeId = "no-such-theme"
        compare(wallpaper.resolvedMotif, "windowLight")
    }

    function test_everyThemeDispatchesToItsMotif() {
        // 遍历所有主题：证明每个 motif 都被 switch 分发到并执行到绘制函数末尾。
        // 将来新增主题若忘写画笔，lastPaintedMotif 停在 "" → 本测试自动变红（覆盖守护）。
        var themes = Theme.backgroundThemes
        for (var i = 0; i < themes.length; i++) {
            wallpaper.themeId = themes[i].id
            ;(function(expected) {
                tryVerify(function() { return wallpaper.lastPaintedMotif === expected }, 3000,
                          "主题 motif " + expected + " 未分发到绘制")
            })(themes[i].motif)
        }
    }

    function test_unknownMotifSkipsDrawingButKeepsGradient() {
        var pc = wallpaper.paintCount
        var mpc = wallpaper.motifPaintCount
        // 注入含非法 motif 的数据源，真实驱动 default 分支。
        wallpaper.themeSource = [{ id: "__probe", name: "探针", base: "#eeeeee", motif: "__no_such_motif", blobs: [] }]
        wallpaper.themeId = "__probe"
        // 渐变仍绘制（背景不开天窗）
        tryVerify(function() { return wallpaper.paintCount > pc }, 3000)
        // 图案分支被跳过：不计数、清空标记
        compare(wallpaper.motifPaintCount, mpc)
        compare(wallpaper.lastPaintedMotif, "")
        // 恢复生产数据源
        wallpaper.themeSource = Theme.backgroundThemes
        wallpaper.themeId = "warmPaper"
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`
Expected: 新测试 FAIL（`resolvedMotif`/`lastPaintedMotif` 未定义）。既有 5 个测试仍应通过。

- [ ] **Step 3: 实现骨架——整体替换 `qml/components/BackgroundWallpaper.qml`**

```qml
import QtQuick
import ".."

// 背景壁纸层：底色 + 三个椭圆径向光晕 + 每主题专属手绘图案（motif）。
// 主题定义唯一来源是 themeSource（生产默认 Theme.backgroundThemes；测试可注入）。
// 未知 themeId 回落首位暖纸；未知 motif 只画渐变不画图案——背景永不开天窗。
Item {
    id: root

    property string themeId: "warmPaper"
    // 数据源默认绑生产单例；测试注入含非法 motif 的数组以覆盖 default 分支。
    property var themeSource: Theme.backgroundThemes
    property alias paintCount: canvas.paintCount
    property alias lastPaintedMotif: canvas.lastPaintedMotif
    property alias motifPaintCount: canvas.motifPaintCount

    // switch 能处理的 motif 清单（自我说明用；运行时覆盖守护由遍历测试保证）。
    readonly property var supportedMotifs: [
        "windowLight", "sunsetPeaks", "orchid", "moonMist", "fallingPetals", "goldenWaves"
    ]

    readonly property var resolvedTheme: {
        var themes = root.themeSource
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === root.themeId) {
                return themes[i]
            }
        }
        return themes[0]
    }

    readonly property string resolvedMotif: root.resolvedTheme && root.resolvedTheme.motif
        ? root.resolvedTheme.motif : ""

    // themeId 与数据源变更都要重绘（显式两条，不依赖 resolvedTheme 变更检测语义）。
    onThemeIdChanged: canvas.requestPaint()
    onThemeSourceChanged: canvas.requestPaint()

    Canvas {
        id: canvas

        property int paintCount: 0
        property int motifPaintCount: 0
        property string lastPaintedMotif: ""

        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            if (width <= 0 || height <= 0) {
                return
            }

            var ctx = getContext("2d")
            var theme = root.resolvedTheme

            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = theme.base
            ctx.fillRect(0, 0, width, height)

            for (var i = 0; i < theme.blobs.length; i++) {
                var blob = theme.blobs[i]
                // createRadialGradient 只支持正圆；缩放坐标系后画单位圆即可得到椭圆光晕。
                ctx.save()
                ctx.translate(blob.cx * width, blob.cy * height)
                ctx.scale(blob.rx * width, blob.ry * height)
                var center = Qt.color(blob.color)
                var gradient = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
                gradient.addColorStop(0, blob.color)
                gradient.addColorStop(1, Qt.rgba(center.r, center.g, center.b, 0))
                ctx.fillStyle = gradient
                ctx.beginPath()
                ctx.arc(0, 0, 1, 0, Math.PI * 2)
                ctx.fill()
                ctx.restore()
            }

            paintMotif(ctx)

            paintCount += 1
        }

        // 图案分发：统一进入 100×62 比例坐标系，按 motif 落到对应画笔。
        function paintMotif(ctx) {
            ctx.save()
            ctx.scale(width / 100, height / 62)
            switch (root.resolvedMotif) {
            case "windowLight": paintWindowLight(ctx); break
            case "sunsetPeaks": paintSunsetPeaks(ctx); break
            case "orchid": paintOrchid(ctx); break
            case "moonMist": paintMoonMist(ctx); break
            case "fallingPetals": paintFallingPetals(ctx); break
            case "goldenWaves": paintGoldenWaves(ctx); break
            default:
                // 未知 motif：清空标记、不计数，只保留已画的底色与光晕。
                lastPaintedMotif = ""
                ctx.restore()
                return
            }
            ctx.restore()
        }

        // —— 六个画笔：本批次仅末行赋值（证明分发到达）；后续批次在赋值行之上补绘制。——
        function paintWindowLight(ctx) {
            lastPaintedMotif = "windowLight"; motifPaintCount += 1
        }

        function paintSunsetPeaks(ctx) {
            lastPaintedMotif = "sunsetPeaks"; motifPaintCount += 1
        }

        function paintOrchid(ctx) {
            lastPaintedMotif = "orchid"; motifPaintCount += 1
        }

        function paintMoonMist(ctx) {
            lastPaintedMotif = "moonMist"; motifPaintCount += 1
        }

        function paintFallingPetals(ctx) {
            lastPaintedMotif = "fallingPetals"; motifPaintCount += 1
        }

        function paintGoldenWaves(ctx) {
            lastPaintedMotif = "goldenWaves"; motifPaintCount += 1
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`（×2）
Expected: 全绿 ×2（含既有 5 个 + 新增 4 个）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/BackgroundWallpaper.qml`
Expected: 零警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/BackgroundWallpaper.qml tests/qml/tst_background_wallpaper.qml
git commit -m "壁纸组件加入 motif 分发骨架与绘制分发驱动属性"
```

---

## 批次二（山/浪 helper + 暮橙、麦浪）

### Task 3: paintSunsetPeaks + paintGoldenWaves（含曲线/径向原语）

**Files:**

- Modify: `qml/components/BackgroundWallpaper.qml`

**Interfaces:**

- Consumes: Task 2 的空 `paintSunsetPeaks`/`paintGoldenWaves`。
- Produces: 绘制原语 `radialGlow`/`solidCircle`/`fillCurveBand`（后续批次复用）。

- [ ] **Step 1: 加绘制原语**

在 `paintMotif` 之前（Canvas 内）加三个 helper：

```qml
        // —— 绘制原语（比例坐标系内，供各 motif 复用）——
        function radialGlow(ctx, cx, cy, r, color, alpha) {
            // 从中心色淡出到全透明的软光；缩放坐标系里非等比会自然拉成椭圆。
            ctx.save()
            ctx.translate(cx, cy)
            ctx.scale(r, r)
            var c = Qt.color(color)
            var g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
            g.addColorStop(0, Qt.rgba(c.r, c.g, c.b, alpha))
            g.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0))
            ctx.fillStyle = g
            ctx.beginPath()
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
        }

        function solidCircle(ctx, cx, cy, r, color, alpha) {
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
        }

        function fillCurveBand(ctx, pts, color, alpha) {
            // pts = [x0,y0, cx1,cy1,x1,y1, cx2,cy2,x2,y2, ...]：一条起伏顶边，向下闭合到底边填充。
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(pts[0], pts[1])
            for (var i = 2; i + 3 < pts.length; i += 4) {
                ctx.quadraticCurveTo(pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
            }
            ctx.lineTo(100, 62)
            ctx.lineTo(0, 62)
            ctx.closePath()
            ctx.fill()
            ctx.restore()
        }
```

- [ ] **Step 2: 填充 paintSunsetPeaks（在末行赋值之上补绘制）**

```qml
        function paintSunsetPeaks(ctx) {
            // 落日外晕（暖白→暖橙→透明三段）
            ctx.save()
            ctx.translate(70, 19)
            ctx.scale(15, 15)
            var sun = ctx.createRadialGradient(0, 0, 0, 0, 0, 1)
            sun.addColorStop(0, Qt.rgba(1, 0.965, 0.894, 0.7))
            sun.addColorStop(0.7, Qt.rgba(1, 0.886, 0.722, 0.35))
            sun.addColorStop(1, Qt.rgba(1, 0.886, 0.722, 0))
            ctx.fillStyle = sun
            ctx.beginPath()
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
            solidCircle(ctx, 70, 19, 8, "#fff3dd", 0.9)
            // 三层珊瑚色远山，越近越沉
            fillCurveBand(ctx, [0, 44, 18, 35, 34, 41, 50, 47, 66, 39, 84, 32, 100, 42], "#e8a17b", 0.24)
            fillCurveBand(ctx, [0, 50, 22, 41, 44, 47, 66, 53, 84, 46, 93, 43, 100, 46], "#d98a68", 0.28)
            fillCurveBand(ctx, [0, 56, 30, 49, 55, 53, 78, 57, 100, 52], "#c67857", 0.30)
            lastPaintedMotif = "sunsetPeaks"; motifPaintCount += 1
        }
```

- [ ] **Step 3: 填充 paintGoldenWaves**

```qml
        function paintGoldenWaves(ctx) {
            radialGlow(ctx, 81, 11, 17, "#fff8dd", 0.55)
            // 三层起伏麦浪由浅入深铺满下沿
            fillCurveBand(ctx, [0, 45, 15, 41, 30, 44, 45, 47, 60, 43, 80, 38, 100, 45], "#eccf8e", 0.32)
            fillCurveBand(ctx, [0, 52, 20, 47, 40, 50, 60, 53, 80, 49, 90, 47, 100, 50], "#e0bd72", 0.38)
            fillCurveBand(ctx, [0, 58, 25, 54, 50, 56, 75, 58, 100, 55], "#d4ad5e", 0.42)
            lastPaintedMotif = "goldenWaves"; motifPaintCount += 1
        }
```

- [ ] **Step 4: 自动回归（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`（×2）
Expected: 全绿 ×2（分发测试不变；绘制不改变属性契约）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/BackgroundWallpaper.qml`
Expected: 零警告。

- [ ] **Step 5: 真机视觉验收（人工，不可用自动测试替代）**

Run: `cmake --build build && cp -R build/PomodoroTodo.app /Applications/番茄Todo.app && open /Applications/番茄Todo.app`
人工确认：设置里切到**暮橙**——落日 + 三层远山剪影，透过玻璃后山影淡雅、不糊文字；切到**麦浪**——右上暖阳 + 三层麦浪。两张缩略图在设置画廊里也应显示对应图案。观感不满意就调对应 `fillCurveBand`/α 后重跑本步，满意再提交。

- [ ] **Step 6: 提交**

```bash
git add qml/components/BackgroundWallpaper.qml
git commit -m "壁纸绘制暮橙落日远山与麦浪金浪"
```

---

## 批次三（光/雾 helper + 暖纸、晨雾）

### Task 4: paintWindowLight + paintMoonMist（含椭圆/多边形/弧线原语）

**Files:**

- Modify: `qml/components/BackgroundWallpaper.qml`

**Interfaces:**

- Consumes: Task 2 空函数 + Task 3 的 `radialGlow`/`solidCircle`。
- Produces: 原语 `fillEllipse`/`fillPolygon`/`strokeArc`。

- [ ] **Step 1: 加绘制原语**

在 `fillCurveBand` 之后加：

```qml
        function fillEllipse(ctx, cx, cy, rx, ry, color, alpha) {
            ctx.save()
            ctx.translate(cx, cy)
            ctx.scale(rx, ry)
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.arc(0, 0, 1, 0, Math.PI * 2)
            ctx.fill()
            ctx.restore()
        }

        function fillPolygon(ctx, pts, color, alpha) {
            // pts = [x0,y0, x1,y1, ...]：闭合多边形填充（斜射光带用）。
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(pts[0], pts[1])
            for (var i = 2; i + 1 < pts.length; i += 2) {
                ctx.lineTo(pts[i], pts[i + 1])
            }
            ctx.closePath()
            ctx.fill()
            ctx.restore()
        }

        function strokeArc(ctx, cx, cy, r, color, lineWidth, alpha) {
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.strokeStyle = color
            ctx.lineWidth = lineWidth
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.stroke()
            ctx.restore()
        }
```

- [ ] **Step 2: 填充 paintWindowLight**

```qml
        function paintWindowLight(ctx) {
            radialGlow(ctx, 22, 14, 17, "#ffffff", 0.55)
            radialGlow(ctx, 80, 50, 21, "#ffffff", 0.32)
            // 斜射入窗的柔光带
            fillPolygon(ctx, [0, 32, 100, 6, 100, 15, 0, 42], "#ffffff", 0.10)
            // 右下角一组极淡同心弧（圆心在画布外下方，只余上缘弧线）
            strokeArc(ctx, 93, 66, 18, "#dfc7a4", 0.5, 0.22)
            strokeArc(ctx, 93, 66, 25, "#dfc7a4", 0.5, 0.14)
            lastPaintedMotif = "windowLight"; motifPaintCount += 1
        }
```

- [ ] **Step 3: 填充 paintMoonMist**

```qml
        function paintMoonMist(ctx) {
            radialGlow(ctx, 27, 13, 11, "#ffffff", 0.5)
            solidCircle(ctx, 27, 13, 5.5, "#ffffff", 0.7)
            // 三条横向雾带渐次下沉
            fillEllipse(ctx, 52, 33, 62, 4.5, "#ffffff", 0.22)
            fillEllipse(ctx, 28, 43, 52, 4, "#e9e9f8", 0.28)
            fillEllipse(ctx, 72, 52, 58, 5, "#dfe4f4", 0.30)
            // 底部一层远丘
            fillCurveBand(ctx, [0, 50, 28, 44, 54, 48, 78, 52, 100, 46], "#b7bdd8", 0.16)
            lastPaintedMotif = "moonMist"; motifPaintCount += 1
        }
```

- [ ] **Step 4: 自动回归（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/BackgroundWallpaper.qml`
Expected: 零警告。

- [ ] **Step 5: 真机视觉验收（人工）**

Run: `cmake --build build && cp -R build/PomodoroTodo.app /Applications/番茄Todo.app && open /Applications/番茄Todo.app`
人工确认：**暖纸**（默认）——斜光带 + 两团暖白光斑 + 右下极淡同心弧，最安静不抢戏；**晨雾**——左上残月 + 三条雾带 + 远丘。不满意调 α/坐标后重跑本步。

- [ ] **Step 6: 提交**

```bash
git add qml/components/BackgroundWallpaper.qml
git commit -m "壁纸绘制暖纸窗光与晨雾月雾"
```

---

## 批次四（笔触/花瓣 helper + 青瓷、樱粉）

### Task 5: paintOrchid + paintFallingPetals（含笔触/花瓣原语）

**Files:**

- Modify: `qml/components/BackgroundWallpaper.qml`

**Interfaces:**

- Consumes: Task 2 空函数 + Task 3 的 `radialGlow`/`solidCircle`。
- Produces: 原语 `strokeQuad`/`fillPetal`。

- [ ] **Step 1: 加绘制原语**

在 `strokeArc` 之后加：

```qml
        function strokeQuad(ctx, x0, y0, cx, cy, x1, y1, color, lineWidth, alpha) {
            // 一笔兰叶：二次贝塞尔描边，圆头收尾。
            ctx.save()
            ctx.globalAlpha = alpha
            ctx.strokeStyle = color
            ctx.lineWidth = lineWidth
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.moveTo(x0, y0)
            ctx.quadraticCurveTo(cx, cy, x1, y1)
            ctx.stroke()
            ctx.restore()
        }

        function fillPetal(ctx, tx, ty, rotDeg, s, color, alpha) {
            // 花瓣基形：泪滴双弧闭合（M0,-3 C1.8,-1.4 1.8,1.6 0,3 C-1.8,1.6 -1.8,-1.4 0,-3 Z）。
            ctx.save()
            ctx.translate(tx, ty)
            ctx.rotate(rotDeg * Math.PI / 180)
            ctx.scale(s, s)
            ctx.globalAlpha = alpha
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(0, -3)
            ctx.bezierCurveTo(1.8, -1.4, 1.8, 1.6, 0, 3)
            ctx.bezierCurveTo(-1.8, 1.6, -1.8, -1.4, 0, -3)
            ctx.closePath()
            ctx.fill()
            ctx.restore()
        }
```

- [ ] **Step 2: 填充 paintOrchid**

```qml
        function paintOrchid(ctx) {
            radialGlow(ctx, 78, 12, 15, "#ffffff", 0.4)
            // 左下角五笔兰叶弧线，由粗到细
            strokeQuad(ctx, 6, 62, 10, 42, 26, 30, "#6fa791", 1.1, 0.38)
            strokeQuad(ctx, 8, 62, 16, 48, 34, 42, "#6fa791", 1.0, 0.30)
            strokeQuad(ctx, 5, 62, 6, 44, 12, 34, "#6fa791", 0.9, 0.26)
            strokeQuad(ctx, 9, 62, 18, 54, 30, 52, "#6fa791", 0.8, 0.20)
            strokeQuad(ctx, 7, 62, 12, 50, 16, 40, "#6fa791", 0.7, 0.16)
            // 两点花苞
            solidCircle(ctx, 27.5, 29, 1.1, "#8fbfae", 0.45)
            solidCircle(ctx, 30, 32, 0.8, "#8fbfae", 0.32)
            lastPaintedMotif = "orchid"; motifPaintCount += 1
        }
```

- [ ] **Step 3: 填充 paintFallingPetals**

```qml
        function paintFallingPetals(ctx) {
            radialGlow(ctx, 16, 12, 16, "#ffd9e4", 0.55)
            // 九片花瓣右上→左下飘落，近大远小、近实远虚
            fillPetal(ctx, 62, 10, 24, 1.4, "#f29db5", 0.50)
            fillPetal(ctx, 74, 18, -38, 1.0, "#eeb0c4", 0.42)
            fillPetal(ctx, 86, 9, 64, 0.8, "#f29db5", 0.35)
            fillPetal(ctx, 90, 30, -15, 1.2, "#eeb0c4", 0.40)
            fillPetal(ctx, 80, 44, 40, 0.9, "#f2a5ba", 0.32)
            fillPetal(ctx, 68, 55, -58, 1.1, "#eeb0c4", 0.28)
            fillPetal(ctx, 38, 52, 18, 0.8, "#f2a5ba", 0.24)
            fillPetal(ctx, 50, 22, -30, 0.7, "#f5bccb", 0.30)
            fillPetal(ctx, 24, 34, 52, 0.9, "#f5bccb", 0.20)
            lastPaintedMotif = "fallingPetals"; motifPaintCount += 1
        }
```

- [ ] **Step 4: 自动回归（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/BackgroundWallpaper.qml`
Expected: 零警告。

- [ ] **Step 5: 真机视觉验收（人工）**

Run: `cmake --build build && cp -R build/PomodoroTodo.app /Applications/番茄Todo.app && open /Applications/番茄Todo.app`
人工确认：**青瓷**——左下角五笔兰叶 + 两点花苞，水墨留白感；**樱粉**——九片花瓣飘落，甜而不腻（花瓣 α 全 ≤0.5）。不满意调笔触/花瓣参数后重跑本步。

- [ ] **Step 6: 提交**

```bash
git add qml/components/BackgroundWallpaper.qml
git commit -m "壁纸绘制青瓷兰草与樱粉落樱"
```

---

## 收尾

### Task 6: 全量回归 + 六张整体验收

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量构建 + 三套测试**

Run: `cmake --build build && ctest --test-dir build --output-on-failure`
Expected: 3/3 通过（QML 套件若 tst_ui_optimization.qml 偶发窗口曝光失败，按既有基线重跑一次区分；本计划改动的 tst_theme_tokens/tst_background_wallpaper 必须稳定绿）。

- [ ] **Step 2: 六张整体真机验收（人工）**

设置画廊里逐张切换六个主题，确认：① 每张图案与设计稿一致；② 透过玻璃后所有页面文字可读性不受影响（重点看最浓的暮橙/麦浪底部 + 樱粉花瓣区）；③ 设置画廊六个缩略图各显示对应图案；④ 切主题即时重绘、无残留。全部通过后向用户汇报，等待确认是否合并回 main（不自行合并）。
