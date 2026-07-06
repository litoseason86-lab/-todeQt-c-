# 背景主题二阶段（壁纸专属图案精美化）设计文档

日期：2026-07-06
状态：六张图案经可视化伴随逐张确认（青瓷一轮否决后重选），技术架构待实施

## 背景

一阶段交付的六张壁纸是"底色 + 3 个椭圆光晕"的程序生成渐变，干净但缺设计感。二阶段在**不换技术栈**（Canvas 手绘、零图片资产、任意分辨率锐利）的前提下，给每张壁纸加一个专属手绘图案，把"生成的渐变"升级为"设计过的壁纸"。

已确认的决策：

- **技术路线**：Canvas 手绘升级（否决：预渲染 PNG——包体积与固定分辨率代价；Shader 微动效——qsb 新建设施 + 学习场景常驻动效耗电）。
- **图案定稿**（可视化伴随两屏确认）：

| 主题 | 图案 | 构成 |
| --- | --- | --- |
| 暖纸 | 窗光 | 斜射柔光带 + 两团暖白光斑 + 右下两圈同心弧 |
| 暮橙 | 落日远山 | 暖白落日（芯 + 晕）+ 三层珊瑚色远山剪影 |
| 青瓷 | 兰草笔意 | 左下角五笔兰叶弧线 + 两点花苞 + 右上光斑（涟漪方案已否决） |
| 晨雾 | 月与雾 | 左上残月（芯 + 晕）+ 三条横向雾带 + 底部远丘 |
| 樱粉 | 落樱 | 九片花瓣右上→左下飘落（近大远小、近实远虚）+ 左上粉晕 |
| 麦浪 | 金浪 | 右上暖阳光斑 + 三层起伏麦浪由浅入深 |

- **可读性约束**（mockup 已带玻璃验证，两类元素分开定标）：
  - **叙事元素**（远山/麦浪/兰叶/花瓣/雾带/远丘/同心弧/花苞——有明确轮廓、构成"图案"的部分）透明度 ≤ 0.45，且集中在边缘/底部/角落；
  - **柔光元素**（径向渐变的光斑/日晕日芯/月晕月芯/粉晕——从中心向外淡出到全透明的软光）允许峰值 α 更高（本规格最高 0.9，见暮橙日芯），因为它们本身就是"从亮到无"的软过渡、无硬边，且全部位于窗口边角；透过 68% 白玻璃后只余一抹亮，不构成可读性干扰。
  - 内容面板核心区（中上部）不落任何叙事元素，只允许柔光元素的淡出尾部经过。
  - 校验口径：**叙事元素 α ≤ 0.45 是硬约束**（下方参数表已全部满足，最高为麦浪三 0.42）；柔光元素不设 α 上限，靠"边角布局 + 径向淡出"保证不干扰。

## 架构

### 数据：Theme.backgroundThemes 增加 motif 字段

每项新增 `motif: "<motifId>"`（`windowLight` / `sunsetPeaks` / `orchid` / `moonMist` / `fallingPetals` / `goldenWaves`）。颜色/光晕定义不变——图案的几何与配色属于绘制代码，不进数据（做通用"形状解释器"是过度设计）。

### 绘制：BackgroundWallpaper 按 motif 分发

- `onPaint` 在现有"底色 + 光晕"之后，按 `resolvedTheme.motif` 用 `switch` 分发到对应绘制函数（`paintWindowLight(ctx)` 等六个）。分发用 `switch(motif){ case "windowLight": paintWindowLight(ctx); break; ... default: /* 未知 motif：不画图案 */ }`，不用"函数名查表"（QML 里按字符串取组件方法不可靠）。
- **测试可测的绘制分发信号**（回应审核第 2 点）：Canvas 暴露 `property string lastPaintedMotif`（初值 `""`）与 `property int motifPaintCount`（初值 0）。每个 `paintXxx(ctx)` 函数**在其函数体最后一行**执行 `canvas.lastPaintedMotif = "<该 motif>"; canvas.motifPaintCount += 1;`——写在最后而非分发时，才能证明"函数体确实执行到了结尾"而非空实现提前返回。default 分支（未知 motif）不触碰这两个属性，`lastPaintedMotif` 保持上一次值或初值 `""`；为让"跳过"可被断言，default 分支显式置 `canvas.lastPaintedMotif = ""`。
- 暴露 `readonly property var supportedMotifs`（六个 motifId 字符串数组）与 `readonly property string resolvedMotif`（`resolvedTheme.motif`，缺失时为 `""`）作为数据侧驱动属性。
- **未知 motif 防御 + 测试入口**（回应审核第 3 点）：`resolvedTheme` 改为读 `property var themeSource`，生产默认 `themeSource: Theme.backgroundThemes`；测试可注入自定义数组（含一个 `motif` 为非法值的项）来真实驱动 default 分支，断言 `lastPaintedMotif === ""` 且不抛错、`paintCount` 仍自增（渐变照画）。这样"未知 motif 跳过图案"从"实现内部防御"升格为可测行为。
- 坐标系：设计稿以 100×62 比例坐标标注。图案绘制统一在 `ctx.save()` 后做一次 `ctx.scale(width / 100, height / 62)` 全局变换，所有元素（含线宽、半径）直接用设计稿数值落笔，画完 `ctx.restore()`。窗口非 100:62 比例时圆会轻微拉成椭圆、线宽轻微各向异性——这与 mockup 的 `preserveAspectRatio="none"` 完全同语义，属定稿观感的一部分。**线宽不做最小值 clamp**（回应审核第 4 点）：缩略图（104×66，与设计稿 100×62 几乎 1:1）与主窗口都按 `ctx.scale` 后的原始线宽绘制；兰叶最细 0.7、弧线 0.5 在缩略图接近 1:1、在主窗口被放大，均不会细到消失，刻意保留"淡描"的轻盈感，不加 `Math.max` 兜底。

### 绘制原语（SVG 设计稿 → Canvas 对照）

| 设计稿元素 | Canvas 实现 |
| --- | --- |
| 径向渐变光斑/日/月晕 | `createRadialGradient` + `arc` 填充 |
| 远山/麦浪/远丘剪影 | `moveTo` + `quadraticCurveTo` 链 + 闭合填充 |
| 雾带（椭圆） | `save/translate/scale` + 单位圆 `arc` 填充（与光晕同法） |
| 兰叶笔触 | `quadraticCurveTo` 描边，`lineCap = "round"` |
| 花瓣 | 两段 `bezierCurveTo` 闭合小路径 + `translate/rotate/scale` 复用 |
| 同心弧/花苞 | `arc` 描边 / 小圆填充 |

## 图案定稿参数（比例坐标，来源 = 已确认 mockup 的 SVG）

### 暖纸 · 窗光（windowLight）

| 元素 | 参数 |
| --- | --- |
| 光斑 ×2 | (22,14) r17 白色径向 α0.55；(80,50) r21 α0.32 |
| 斜光带 | 四边形 (0,32)→(100,6)→(100,15)→(0,42) 白 α0.10 |
| 同心弧 ×2 | 圆心 (93,66) r18 α0.22、r25 α0.14，描边 `#dfc7a4` 线宽 0.5 |

### 暮橙 · 落日远山（sunsetPeaks）

| 元素 | 参数 |
| --- | --- |
| 日晕 | (70,19) r15 径向 `#fff6e4`→透明 α0.7 |
| 日芯 | (70,19) r8 `#fff3dd` α0.9 |
| 远山一 | (0,44) Q(18,35)(34,41) Q(50,47)(66,39) Q(84,32)(100,42) 闭合 `#e8a17b` α0.24 |
| 远山二 | (0,50) Q(22,41)(44,47) Q(66,53)(84,46) Q(93,43)(100,46) 闭合 `#d98a68` α0.28 |
| 远山三 | (0,56) Q(30,49)(55,53) Q(78,57)(100,52) 闭合 `#c67857` α0.30 |

### 青瓷 · 兰草笔意（orchid）

| 元素 | 参数 |
| --- | --- |
| 光斑 | (78,12) r15 白色径向 α0.4 |
| 兰叶 ×5 | 起点均在左下缘 x5〜9 / y62：Q(10,42)(26,30) 宽1.1 α0.38；Q(16,48)(34,42) 宽1.0 α0.30；Q(6,44)(12,34) 宽0.9 α0.26；Q(18,54)(30,52) 宽0.8 α0.20；Q(12,50)(16,40) 宽0.7 α0.16——描边 `#6fa791`，圆头 |
| 花苞 ×2 | (27.5,29) r1.1 α0.45；(30,32) r0.8 α0.32，填充 `#8fbfae` |

### 晨雾 · 月与雾（moonMist）

| 元素 | 参数 |
| --- | --- |
| 月晕 | (27,13) r11 白色径向 α0.5 |
| 月芯 | (27,13) r5.5 白 α0.7 |
| 雾带 ×3 | 椭圆 (52,33) rx62 ry4.5 白 α0.22；(28,43) rx52 ry4 `#e9e9f8` α0.28；(72,52) rx58 ry5 `#dfe4f4` α0.30 |
| 远丘 | (0,50) Q(28,44)(54,48) Q(78,52)(100,46) 闭合 `#b7bdd8` α0.16 |

### 樱粉 · 落樱（fallingPetals）

花瓣基形：`M0,-3 C1.8,-1.4 1.8,1.6 0,3 C-1.8,1.6 -1.8,-1.4 0,-3 Z`（泪滴双弧闭合）。

| 元素 | 参数（translate / rotate / scale / 色 / α） |
| --- | --- |
| 粉晕 | (16,12) r16 `#ffd9e4` 径向 α0.55 |
| 花瓣 ×9 | (62,10)/24°/1.4/`#f29db5`/0.50；(74,18)/−38°/1.0/`#eeb0c4`/0.42；(86,9)/64°/0.8/`#f29db5`/0.35；(90,30)/−15°/1.2/`#eeb0c4`/0.40；(80,44)/40°/0.9/`#f2a5ba`/0.32；(68,55)/−58°/1.1/`#eeb0c4`/0.28；(38,52)/18°/0.8/`#f2a5ba`/0.24；(50,22)/−30°/0.7/`#f5bccb`/0.30；(24,34)/52°/0.9/`#f5bccb`/0.20 |

### 麦浪 · 金浪（goldenWaves）

| 元素 | 参数 |
| --- | --- |
| 阳光斑 | (81,11) r17 `#fff8dd` 径向 α0.55 |
| 麦浪一 | (0,45) Q(15,41)(30,44) Q(45,47)(60,43) Q(80,38)(100,45) 闭合 `#eccf8e` α0.32 |
| 麦浪二 | (0,52) Q(20,47)(40,50) Q(60,53)(80,49) Q(90,47)(100,50) 闭合 `#e0bd72` α0.38 |
| 麦浪三 | (0,58) Q(25,54)(50,56) Q(75,58)(100,55) 闭合 `#d4ad5e` α0.42 |

## 错误处理

- `motif` 字段缺失或无对应绘制函数：跳过图案层，只画底色 + 光晕（背景永不开天窗）；
- 既有防御不变：零尺寸跳过绘制、未知 themeId 回落暖纸、噪点瓦片禁用（`test_noTiledNoiseTextureLayer` 守护）。

## 测试策略（QML，全部驱动属性断言）

- **Theme 定义**：六项都有非空 `motif` 字段（扩展 `test_backgroundThemesDefinitions`）；
- **覆盖守护**（防"新主题没画笔静默无图案"）：`Theme.backgroundThemes` 每项的 `motif` 都 ∈ `wallpaper.supportedMotifs`；
- **数据分发正确**：`themeId = "celadon"` 后 `resolvedMotif === "orchid"`；未知 themeId 回落后 `resolvedMotif === "windowLight"`（暖纸的 motif）；
- **绘制分发真的发生（覆盖守护升级版，回应审核第 2 点）**：**遍历** `Theme.backgroundThemes`，对每张 `themeId = t.id` 后 `tryVerify(lastPaintedMotif === t.motif && lastPaintedMotif !== "")`——证明每个主题的 `paintXxx` 都被调用且执行到函数末尾。因为是遍历而非硬编码六项，**将来新增主题若 motif 无对应 `switch` 分支，lastPaintedMotif 停在 "" → 测试自动变红**，这一条同时充当"新主题没画笔"的覆盖守护（比静态 `∈ supportedMotifs` 更强，直接验证运行时到达绘制）；
- **未知 motif 跳过可测**（回应审核第 3 点）：`wallpaper.themeSource = [{ id:"__t", base:"#eeeeee", blobs:[], motif:"__no_such_motif" }]` 且 `themeId = "__t"`，`tryVerify(paintCount 增加)`（渐变仍画）后断言 `lastPaintedMotif === ""`（图案被跳过）且无异常；测试末尾恢复 `themeSource = Theme.backgroundThemes`；
- **重绘行为不回归**：既有 `paintCount` 测试继续通过（图案在同一 onPaint 内，无新重绘时机）；`test_noTiledNoiseTextureLayer` 继续通过；
- **纪律不变**：不断言 `visible === true`，不做像素抓取。

## 影响面与拆分

- 仅两个文件：`qml/Theme.qml`（六行 motif 字段）+ `qml/components/BackgroundWallpaper.qml`（分发骨架 + 绘制原语 helper + 六个绘制函数，实际预计 **350–450 行**，审核第 5 点已修正预估）；测试改 `tst_theme_tokens.qml` + `tst_background_wallpaper.qml`。
- SettingsDialog、MainWindow、各视图零改动（缩略图同组件自动生效）。
- **单份实施计划、分阶段提交**（回应审核第 5 点：一次补 350+ 行 Canvas 难审，按可独立验证的批次落地）：
  1. 数据层：Theme 六个 `motif` 字段 + `supportedMotifs`/`resolvedMotif`/`themeSource`/`lastPaintedMotif`/`motifPaintCount` 骨架 + `switch` 空分发（每个 `paintXxx` 先只写末行赋值），测试：定义完整性 + 覆盖守护 + 数据分发 + 未知 motif 跳过全部转绿——此时"分发管道"已被测试锁死；
  2. 第一批两个 motif（sunsetPeaks + goldenWaves，共用远山/波浪曲线原语，先立 helper）实体绘制 + 真机看图；
  3. 第二批两个 motif（windowLight + moonMist，共用径向柔光/椭圆雾带原语）；
  4. 第三批两个 motif（orchid 兰叶笔触 + fallingPetals 花瓣原语）。
  每批一次提交、独立可视验证；`lastPaintedMotif` 测试在第 1 批已全绿（空实现也满足末行赋值），因此每批只需真机确认图案观感，测试不重复。
