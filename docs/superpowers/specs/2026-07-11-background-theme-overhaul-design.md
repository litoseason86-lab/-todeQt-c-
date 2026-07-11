# 背景主题系统大改：六张 AI 壁纸 + 暖纸夜间版 + 侧栏毛玻璃

日期：2026-07-11（多轮实机迭代，2026-07-12 收尾）
状态：已实现、已合入 main（详见项目记忆 theme-overhaul-plan-2026-07）。本文档为最终实现的事后记录。

## 最终形态

推翻现有六款 Canvas 程序化绘制的"简笔画"背景主题，替换为：

1. **六张照片级 AI 生成壁纸**（用户用 ChatGPT Plus 生成，已入库 `resources/wallpapers/`）；
2. **UI 色相永远是暖纸家族**，不随壁纸切换主题色板；
3. **暗色壁纸自动切换到"暖纸夜间版"**：只翻转明暗（米白墨水 + 暗暖玻璃），强调色/色相不变；
4. **侧栏是全应用唯一的真实毛玻璃区**：对静态壁纸做一次区域采样模糊，卡片/按钮维持半透明蒙层，不逐一实时模糊。

审美基准：虚焦摄影感壁纸、克制的高级感；忌密集小图案、贴纸感、程序化绘制的具象元素、大片不透明白块。

## 决策过程（供后续维护者理解为什么不是"每主题一套色板"）

实现过程中先后尝试并被用户否掉的方向：

1. **每主题一整套 UI 色板**（含暗色界面、多彩分类色盘、随主题切换的 accent/ink/glass）——实机看后用户认为"不像同一个 App"，且暗色分类色映射增加了不必要的复杂度，最终**全部回退**；
2. **UI 固定暖纸 + 壁纸罩层遮盖**（明亮 18%/暗色 30% 暖白纱压在壁纸上保可读性）——用户反馈"白雾太多不精美"，**罩层机制整体删除**；
3. **UI 固定暖纸 + 无罩层玻璃透壁纸**——明亮三款（暖/粉/江南）效果良好，但暗色三款下暖褐色文字压在深色壁纸透出的玻璃上完全不可读（用户原话"这是能看的吗"）；
4. **最终定案：暖纸夜间版**——不逐 token 手改，而是给 Theme 增加一个 `darkMode` 派生位（由当前壁纸的 `mode` 字段决定），墨水/玻璃/语义色按明暗各存一套值，色相（尤其 accent 焦糖棕）两版共用同一色号，只翻转明暗关系。这样"UI 永远是暖纸"的用户要求和"暗色壁纸必须可读"的物理约束同时满足。

## 主题阵容（六款）

| id | 名称 | mode | 壁纸文件 | 定位 |
| --- | --- | --- | --- | --- |
| `warm` | 暖色 | light | warm.png | 默认主题，旧暖纸精神续作 |
| `pink` | 粉色 | light | pink.png | 樱花虚焦散景 |
| `jiangnan` | 烟雨江南 | light | jiangnan.png | 水墨湖山 |
| `starry` | 星空 | dark | starry.png | 星云星野 |
| `rainy` | 雨夜窗景 | dark | rainy.png | 夜窗水珠光斑 |
| `moon` | 月夜山影 | dark | moon.png | 月下层叠山影 |

默认主题为 `warm`。`Theme.themes[i].mode` 是唯一驱动 UI 明暗切换的字段——不存在"每个主题独立色板"，只有 light/dark 两套 UI 版式。

### 旧 id 迁移

| 旧 id | warmPaper | sunset | wheat | celadon | mist | sakura |
| --- | --- | --- | --- | --- | --- | --- |
| 新 id | warm | warm | warm | jiangnan | jiangnan | pink |

`Theme.migrateThemeId()` 负责映射，未知值原样返回，`Theme.resolveTheme()` 对无法解析的 id 回落 `themes[0]`（warm）。MainWindow 启动时把设置里的旧 id 迁移写回，此后设置存的都是新 id。

## 壁纸层（BackgroundWallpaper）

- Canvas 绘制已完全移除，组件改为 `Image`：`fillMode: PreserveAspectCrop`、`asynchronous: true`、`cache: true`。
- 壁纸资源：`resources/wallpapers/{warm,pink,jiangnan,starry,rainy,moon}.png`（1536×1024），`resources/wallpapers.qrc` 打包，`WallpaperAssetsTests.cpp` 守门六张图可解码且尺寸正确。
- `wallpaperBase` 兜底 Rectangle 在图片加载完成前显示主题 `base` 纯色，避免白闪/黑闪。
- **无罩层**：壁纸原图直接展示，可读性完全交给下方的暖纸夜间版机制，不再用半透明纱压暗壁纸。
- 沉浸式专注全屏（`FocusImmersiveOverlay`）直接铺 `BackgroundWallpaper`，是壁纸氛围展示最完整的场景。

## Theme.qml：darkMode 派生 token

- `Theme.activeThemeId`：由 `MainWindow` 的 `Binding` 绑定到 `appSettingsRef.backgroundTheme`（经 `migrateThemeId` 归一化）。
- `Theme.darkMode: resolveTheme(activeThemeId).mode === "dark"`：唯一的明暗开关。
- 受 `darkMode`影响的 token：`surface*`、`border*`、`ink*`、`accentSoft`、`accentInk`、`success/danger` 系、`chartColors`、`focusRingTrack`、`focusGlass*`、`focusColonMuted`、`glassSidebar/glassCard/glassHover/glassAccent/glassDialog/glassBorder`。
- **不受影响、两版同值**：`accent`、`accentStrong`、`shadow`、字号/字族/间距/圆角、`focusRingArcStart/Mid/End`（专注环弧光两版共用暖金渐变）。
- 新增的语义 token：
  - `glassHover`：卡片/按钮悬停态，比 `glassCard` 实一档；
  - `glassAccent`：选中态/高亮底（侧栏选中项、倒计时横幅、沉浸完成态横幅），是 `accentSoft` 的半透明版。

## 组件改动（透壁纸玻璃化）

以下不透明的 `surface`/`accentSoft` 底全部换成对应的玻璃 token，让壁纸透出：

- `TaskItem` 任务卡：`surface`/`surfaceRaised` → `glassCard`/`glassHover`；
- 周计划页三态按钮（上一周/本周/下一周/编辑/删除等，`WeekPlanView`、`MonthGoalView`、`CountdownDialog`、`RoutineDialog`、`AddTaskDialog` 共用的三态写法）：`surface`/`surfaceSunken`/`borderSubtle` 组合 → `glassCard`/`glassHover`；
- 周计划星期脊柱（日期牌）：`surfaceRaised`/`surfaceSunken` → `glassCard`（今天仍用 `accent` 实色高亮）；
- `Sidebar` 选中项底色、图标小方块：`accentSoft`/`border` → `glassAccent`/`glassCard`；
- `CountdownBanner` 渐变、`TodayTaskView` 顺延提醒横幅、`FocusImmersiveOverlay` 完成态横幅：`accentSoft` → `glassAccent`（`CountdownBanner` 是渐变，两端都换成半透明色）。

弹窗背景（`glassDialog`，98.5% 不透明）不做玻璃化处理——弹窗需要完全遮盖下方内容，两个明暗版各有一份接近实底的值。

## 侧栏真实毛玻璃

- `MainWindow.qml` 新增一个独立于 `mainContentRow` 的 `sidebarFrost` Item（208px 宽，随 `focusImmersiveActive` 隐藏），内部：
  1. `ShaderEffectSource` 对 `wallpaperLayer`（壁纸层）按侧栏区域采样一次；
  2. `MultiEffect` 对采样结果做 `blurEnabled: true, blur: 0.9, blurMax: 48`；
  3. `Sidebar` 组件本身叠在其上，用半透明 `glassSidebar` 上色。
- 这是全应用唯一的实时模糊区域；卡片/按钮不做逐一模糊（性能考虑，壁纸是静态图，模糊一次即可覆盖所有卡片场景，视觉差异可忽略）。
- 未采用原生 NSVisualEffectView（该路径 2026-06 已试验并放弃，见项目记忆 番茄todo-mac-vibrancy）；这里的"毛玻璃"是纯 QML 后处理效果，跨平台一致。

## 测试

- `WallpaperAssetsTests.cpp`：六张壁纸 qrc 存在、可解码、尺寸 1536×1024（offscreen 平台）。
- `tst_theme_palettes.qml`：六主题阵容、mode 标记、壁纸元数据字段、旧 id 迁移、`resolveTheme` 回落。
- `tst_theme_tokens.qml`：默认 warm 态的固定色值；`test_darkWallpaperSwitchesToNightVariant` 验证切到 `moon` 后墨水/玻璃切换到夜间版而 `accent` 保持不变，切回 `pink` 后日间版复原。
- `tst_background_wallpaper.qml`：主题解析、迁移、`wallpaperImage` 加载、`wallpaperBase` 兜底色匹配；已删除罩层相关用例（罩层机制已整体移除）。
- `tst_focus_immersive.qml`：沉浸态背景显示壁纸图片（`wallpaperImage` source 指向壁纸资源）。
- `tst_sidebar_ui_optimization.qml`：侧栏选中态断言更新为 `glassAccent`，图标底断言更新为 `glassCard`。
- 沿用项目 QML 测试红线：不断言 `item.visible === true`。

## 验收结论

- 六款主题逐一切换：壁纸、侧栏（真实模糊）、卡片、按钮、文字、图表、专注环全部随明暗自动适配，无残留不透明白块；
- 暗色主题下正文文字对比经暖纸夜间版校正后可读；
- 主题切换即时生效、无需重启；
- 视觉验收基准：Artifact「番茄todo · 背景主题设计稿」+ 用户多轮实机截图反馈。
