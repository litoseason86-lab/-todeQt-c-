# 背景主题系统大改：六张 AI 壁纸 + 全套 UI 色板随主题切换

日期：2026-07-11
状态：已实现并经多轮实机迭代定稿。
**最终定稿（2026-07-11 实机验收后用户拍板，覆盖本文关于 UI 色板的所有内容）：
只换壁纸，UI 色值永远保持原版暖纸令牌不变。** 随主题切换的 UI 色板机制
（palette/activeThemeId、暗色界面、多彩分类色盘）已全部移除；保留的内容：
六张壁纸 + qrc 资源、themes 壁纸元数据（id/name/mode/base/wallpaper/wallpaperScrim）、
旧 id 迁移、壁纸罩层（明亮 18% / 暗色 30% 暖白纱保可读性）。

## 目标

推翻现有六款 Canvas 程序化绘制的"简笔画"背景主题，替换为：

1. **六张照片级 AI 生成壁纸**（用户用 ChatGPT Plus 生成，已入库）；
2. **每主题一整套 UI 色板**：文字墨水、玻璃/卡片、边框、强调色、图表色全部随主题切换；
3. **三款暗色主题**带完整暗色界面（浅色文字、暗色玻璃）。

审美基准（用户反复校准后定案，详见记忆 background-theme-aesthetic-feedback）：
虚焦摄影感、大面积留白、克制的高级感；忌密集小图案、贴纸感、程序化绘制的具象元素。

## 非目标

- 不新增功能（参考图中的问候语头部、用户资料卡、音乐播放条等一律不做）；
- 不做动态/动画壁纸；
- 不改字体系统；
- 番茄图标、布局、组件结构不动——只换"颜色与背景"。

## 主题阵容（六款，id 为新标识）

| id | 名称 | 明/暗 | 壁纸文件 | 强调色 | 定位 |
| --- | --- | --- | --- | --- | --- |
| `warm` | 暖色·晨光 | 明亮 | warm.png | 蜂蜜琥珀 `#dc9550` | 默认主题，旧暖纸精神续作 |
| `pink` | 粉色·樱雾 | 明亮 | pink.png | 深玫瑰粉 `#e5638f` | 樱花虚焦散景 |
| `jiangnan` | 烟雨江南 | 明亮 | jiangnan.png | 青瓷绿 `#5f9e85` | 水墨湖山 |
| `starry` | 星空 | 暗色 | starry.png | 星雾紫 `#8f7ff0` | 星云星野 |
| `rainy` | 雨夜窗景 | 暗色 | rainy.png | 暖琥珀 `#e8a34e` | 夜窗水珠光斑 |
| `moon` | 月夜山影 | 暗色 | moon.png | 月光青蓝 `#7fa8d9` | 月下层叠山影 |

默认主题为 `warm`（延续旧默认"暖纸"的气质）。

### 旧 id 迁移

设置里已持久化的旧值按下表映射，未知值回落 `warm`：

| 旧 id | warmPaper | sunset | celadon | mist | sakura | wheat |
| --- | --- | --- | --- | --- | --- | --- |
| 新 id | warm | warm | jiangnan | jiangnan | pink | warm |

（旧主题全部为浅色，因此迁移目标一律选浅色款，不把老用户突然切进暗色界面。）

## 壁纸层（BackgroundWallpaper 重写）

- **放弃 Canvas 绘制**。组件改为 `Image`：`fillMode: PreserveAspectCrop`、异步加载、
  `sourceSize` 限制为窗口所需尺寸避免超采样。
- 壁纸资源：`resources/wallpapers/{warm,pink,jiangnan,starry,rainy,moon}.png`（1536×1024，已入库），
  新建 `resources/wallpapers.qrc` 并接入 CMake。
- 图片未加载完成/加载失败时显示该主题的 `base` 底色（每主题定义一个与壁纸主色调一致的纯色），
  不出现白闪或黑闪。
- 组件对外接口保持 `themeId`，未知 id 回落默认主题（表首 `warm`）。
- 旧 motif 绘制原语、`supportedMotifs`、`paintCount` 等 API 随 Canvas 一并删除。

## 主题色板系统（Theme.qml 升级）

### 结构

- `Theme.themes`：六个主题的完整定义数组（id、名称、mode、壁纸 URL、base、全套色板 token）。
- `Theme.activeThemeId`：由设置注入；`Theme.palette` 解析为当前主题色板。
- **兼容层**：现有 `Theme.ink`、`Theme.surface`、`Theme.accent` 等全部属性名保留，
  改为绑定到 `palette` 的对应 token——存量组件不用改引用，颜色即自动随主题切换。
- 组件中所有硬编码颜色（如有）在实现时一并清理为 Theme 引用。

### 每主题 token 清单（与现 Theme.qml 分区一致）

墨水 `inkStrong/ink/inkSoft/inkMuted`、表面 `surface/surfaceRaised/surfaceSunken`、
边框 `border/borderSubtle`、强调 `accent/accentStrong/accentSoft/accentInk`、
玻璃 `glassSidebar/glassCard`、语义 `success/danger` 系、`shadow`、
图表 `chartColors[]`、专注环 `focusRing*` / `focusGlass*` 系。

### 已审核定案的核心色值

**明亮三款**（表面/边框在现值基础上做同色相微调，语义色沿用现值）：

| token | warm | pink | jiangnan |
| --- | --- | --- | --- |
| accent | #dc9550 | #e5638f | #5f9e85 |
| inkStrong | #52422e | #573f4b | #39473f |
| ink | #6b573d | #6d525f | #54655c |
| inkSoft | #9c8266 | #a37f8f | #84948a |
| glassSidebar | #fffaf2 @55% | #fff2f6 @55% | #f8fcfa @55% |
| glassCard | #fffcf6 @70% | #fffafc @70% | #fcfefd @70% |
| accentSoft(选中底) | #f7e5c8 | #fadbe6 | #dcece3 |

**暗色三款**（浅色墨水 + 暗色玻璃；语义色 success/danger 提亮一档保证对比）：

| token | starry | rainy | moon |
| --- | --- | --- | --- |
| accent | #8f7ff0 | #e8a34e | #7fa8d9 |
| inkStrong | #eceafb | #f0ebe2 | #e9eff7 |
| ink | #c6c2e0 | #c9c3b6 | #c0cbd9 |
| inkSoft | #8f8ab0 | #8f8c84 | #8494a6 |
| glassSidebar | #14122a @55% | #101826 @55% | #0c1626 @55% |
| glassCard | #201e3e @62% | #1a2434 @62% | #142032 @62% |
| accentSoft(选中底) | accent @22–28% | 同左 | 同左 |

### 派生规则（未逐一列出的 token）

- `accentStrong`＝accent 加深一档；`accentInk`＝accent 压到 AA 对比达标；
- `surface*`＝对应玻璃色的不透明近似（明亮款近白、暗色款近玻璃底色）；
- `border*`＝ink 与 surface 的低对比中间值；
- `chartColors`、`focusRing*`、`focusGlass*` 按各主题强调色同族推导（暗色主题轨道/玻璃用暗色系）；
- 推导值在实现时落库为显式 hex（不留运行时计算），并以实机截图验收。

## 暗色模式的系统面

- 本应用的"玻璃"是 QML 半透明色块（白/暗 + alpha 叠在壁纸上），**没有**原生
  NSVisualEffectView（该方案 2026-06 已试验并放弃，勿引入）。暗色主题只需把
  glass 系 token 换成暗色半透明值，无系统层改动。
- 弹窗、Toast、沉浸式专注层等全部消费 Theme token，无需单独适配，但需逐一目检。

## 设置与持久化

- 沿用现有 `appSettings.backgroundTheme` 键；启动时执行旧 id 迁移（见上表）。
- SettingsDialog 的主题选择器更新为六款新主题，选项预览用壁纸缩略图 + 主题名
  （缩略图直接引用壁纸资源，缩小显示）。

## 测试

- `tst_background_wallpaper.qml` 重写：六主题 id → 壁纸 source 映射、未知 id 回落、
  base 兜底色存在；删除全部 motif/paintCount 断言。
- Theme 测试：六主题 token 完整性（每主题都能解析出全部 token）、旧 id 迁移映射、
  明暗 mode 标记正确。
- 沿用项目 QML 测试红线：不断言 `item.visible === true`（见记忆 qml-test-visible-assertion-pitfall）。
- 图片资源存在性测试（qrc 内六张壁纸可加载）。

## 验收

- 六款主题逐一切换：壁纸、侧栏、卡片、按钮、文字、图表、专注环全部随之变化，无残留旧配色；
- 暗色主题下所有正文文字对比 ≥ AA；
- 主题切换即时生效、无需重启；
- 设计稿（Artifact「番茄todo · 背景主题设计稿」）为视觉验收基准。
