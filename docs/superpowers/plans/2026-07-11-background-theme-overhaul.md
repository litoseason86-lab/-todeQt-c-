# 背景主题大改（六张 AI 壁纸 + 全套 UI 色板随主题）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把六款 Canvas 程序化背景替换为六张已入库的照片级壁纸，并让整套 UI 色板（墨水/玻璃/强调/图表/专注环）随主题切换，含三款暗色主题。

**Architecture:** Theme.qml 单例新增 `themes` 数组（六主题完整色板 + 壁纸 URL）与 `activeThemeId`/`palette` 解析层；所有现有 token 属性名保留、改绑 `palette`，存量组件零改动跟随换色。BackgroundWallpaper 由 Canvas 重写为 `Image`。旧主题 id 在 Theme 层迁移映射。

**Tech Stack:** Qt 6 / QML（Qt Quick, qmltestrunner）、CMake、qrc 资源。

**Spec:** `docs/superpowers/specs/2026-07-11-background-theme-overhaul-design.md`

## Global Constraints

- 壁纸六张已存在：`resources/wallpapers/{warm,pink,jiangnan,starry,rainy,moon}.png`，均 1536×1024，不得改名。
- 新主题 id 固定为 `warm / pink / jiangnan / starry / rainy / moon`，默认 `warm`（themes 数组首位必须是 warm）。
- 旧 id 迁移表：warmPaper→warm、sunset→warm、wheat→warm、celadon→jiangnan、mist→jiangnan、sakura→pink。
- QML 测试红线：**禁止断言 `item.visible === true`**（本项目沙箱下不可靠且会级联失败）。
- 不引入原生 NSVisualEffectView / NSAppearance（2026-06 试验已放弃）；"玻璃"= QML 半透明色块。
- 弹窗遮罩色（#66000000/#8c000000）、ColorPicker 与分类默认色（#d4a574 系）是用户数据/遮罩语义，**不属于主题范围，不改**。
- 提交信息用中文短句、无前缀（仓库既有风格，如"沉浸模式移除铃声快捷开关"）。
- 构建：`cmake --build build -j8`；测试：`ctest --test-dir build --output-on-failure`（QML 套件名 `PomodoroTodoQmlTests`）。

---

### Task 1: 壁纸 qrc 打包 + 资产守门测试

**Files:**

- Create: `resources/wallpapers.qrc`
- Create: `tests/WallpaperAssetsTests.cpp`
- Modify: `CMakeLists.txt`（app 资源列表 ~72 行处；新测试目标加在 FontAssetsTests 块之后 ~205 行处）

**Interfaces:**

- Consumes: 已入库的六张 png。
- Produces: qrc URL 约定 `qrc:/resources/wallpapers/<id>.png`（Task 2 的 Theme 用 `Qt.resolvedUrl("../resources/wallpapers/<id>.png")` 引用，两种运行环境——app 的 qrc 与 qmltestrunner 的源码目录——都能解析到）。

- [ ] **Step 1: 写失败测试** — 创建 `tests/WallpaperAssetsTests.cpp`：

```cpp
#include <QtTest>
#include <QImage>

// 壁纸资源守门：六张主题壁纸必须打包进 qrc、可解码、尺寸 1536×1024。
class WallpaperAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void wallpaperAssets_data()
    {
        QTest::addColumn<QString>("path");
        const char* names[] = { "warm", "pink", "jiangnan", "starry", "rainy", "moon" };
        for (const char* name : names) {
            QTest::newRow(name)
                << QStringLiteral(":/resources/wallpapers/%1.png").arg(QLatin1String(name));
        }
    }

    void wallpaperAssets()
    {
        QFETCH(QString, path);
        QVERIFY2(QFile::exists(path), qPrintable(path + QStringLiteral(" 不在 qrc 里")));
        QImage image(path);
        QVERIFY2(!image.isNull(), qPrintable(path + QStringLiteral(" 无法解码")));
        QCOMPARE(image.size(), QSize(1536, 1024));
    }
};

QTEST_MAIN(WallpaperAssetsTests)
#include "WallpaperAssetsTests.moc"
```

- [ ] **Step 2: 注册测试目标** — `CMakeLists.txt` 在 `add_test(NAME FontAssetsTests ...)`/其 `set_tests_properties` 块之后追加：

```cmake
add_executable(WallpaperAssetsTests
    tests/WallpaperAssetsTests.cpp
    resources/wallpapers.qrc
)

target_link_libraries(WallpaperAssetsTests PRIVATE
    Qt6::Gui
    Qt6::Test
)

add_test(NAME WallpaperAssetsTests COMMAND WallpaperAssetsTests)
set_tests_properties(WallpaperAssetsTests PROPERTIES
    # 图片解码无需真实窗口；offscreen 保证后台不弹窗。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)
```

- [ ] **Step 3: 构建验证失败** — Run: `cmake --build build -j8`
  Expected: FAIL —— `resources/wallpapers.qrc` 不存在，CMake/RCC 报错。

- [ ] **Step 4: 创建 qrc** — 创建 `resources/wallpapers.qrc`（alias 保持与源码树同形，QML 里相对路径在 qrc 与源码两种环境下都可解析）：

```xml
<RCC>
    <qresource prefix="/">
        <file alias="resources/wallpapers/warm.png">wallpapers/warm.png</file>
        <file alias="resources/wallpapers/pink.png">wallpapers/pink.png</file>
        <file alias="resources/wallpapers/jiangnan.png">wallpapers/jiangnan.png</file>
        <file alias="resources/wallpapers/starry.png">wallpapers/starry.png</file>
        <file alias="resources/wallpapers/rainy.png">wallpapers/rainy.png</file>
        <file alias="resources/wallpapers/moon.png">wallpapers/moon.png</file>
    </qresource>
</RCC>
```

- [ ] **Step 5: 接入 app 目标** — `CMakeLists.txt` 中 app 目标资源列表（现为第 72-73 行）：

```cmake
    resources/qml.qrc
    resources/wallpapers.qrc
    resources/fonts.qrc
```

- [ ] **Step 6: 构建并跑测试** — Run: `cmake --build build -j8 && ctest --test-dir build -R WallpaperAssetsTests --output-on-failure`
  Expected: PASS（6 个数据行全过）。

- [ ] **Step 7: Commit**

```bash
git add resources/wallpapers.qrc tests/WallpaperAssetsTests.cpp CMakeLists.txt
git commit -m "壁纸资源打包进qrc并加资产守门测试"
```

---

### Task 2: Theme 新增主题系统（themes / palette / 迁移），与旧 token 并存

**Files:**

- Modify: `qml/Theme.qml`（在文件末尾 `backgroundThemes` 数组**之后**追加新块；本任务不动任何现有属性）
- Create: `tests/qml/tst_theme_palettes.qml`

**Interfaces:**

- Consumes: Task 1 的壁纸路径约定。
- Produces（后续任务依赖的精确签名）:
  - `Theme.activeThemeId : string`（可写，默认 `"warm"`）
  - `Theme.themes : var`（六元素数组，字段见 Step 3 代码）
  - `Theme.palette : var`（当前主题对象，随 activeThemeId 重解析）
  - `Theme.migrateThemeId(themeId: string) : string`（旧 id → 新 id，未知原样返回）
  - `Theme.resolveTheme(themeId: string) : var`（含迁移；未知回落 themes[0]）

- [ ] **Step 1: 写失败测试** — 创建 `tests/qml/tst_theme_palettes.qml`：

```qml
import QtQuick
import QtTest
import "../../qml"

// 主题系统 v2：六主题定义完整性、旧 id 迁移、palette 随 activeThemeId 切换。
TestCase {
    name: "ThemePalettes"

    function init() {
        Theme.activeThemeId = "warm"
    }

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

    function test_everyThemeHasFullTokenSet() {
        var keys = ["name", "base", "wallpaper",
            "surface", "surfaceRaised", "surfaceSunken",
            "border", "borderSubtle",
            "inkStrong", "ink", "inkSoft", "inkMuted",
            "accent", "accentStrong", "accentSoft", "accentInk",
            "success", "danger", "dangerBorder", "dangerSoft",
            "chartColors",
            "focusRingArcStart", "focusRingArcMid", "focusRingArcEnd", "focusRingTrack",
            "focusGlassCenter", "focusGlassEdge", "focusGlassShadow",
            "focusGlassHighlight", "focusColonMuted",
            "glassSidebar", "glassCard", "glassDialog", "glassBorder"]
        for (var i = 0; i < Theme.themes.length; i++) {
            var t = Theme.themes[i]
            for (var k = 0; k < keys.length; k++) {
                verify(t[keys[k]] !== undefined, t.id + " 缺 token: " + keys[k])
            }
            compare(t.chartColors.length, 6, t.id + " chartColors 应为 6 色")
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

    function test_paletteFollowsActiveThemeId() {
        compare(Theme.palette.id, "warm")
        Theme.activeThemeId = "starry"
        compare(Theme.palette.id, "starry")
        compare(Theme.palette.mode, "dark")
    }
}
```

- [ ] **Step 2: 验证失败** — Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
  Expected: FAIL —— `ThemePalettes` 各用例报 `Theme.themes`/`migrateThemeId` 未定义。

- [ ] **Step 3: 实现** — `qml/Theme.qml` 在 `backgroundThemes` 数组的 `]` 之后（文件末 `}` 之前）追加：

```qml
    // ══ 主题系统 v2：壁纸图片 + 每主题一套完整色板 ══
    // activeThemeId 由 MainWindow 绑定设置注入；palette 为当前主题对象。
    // themes[0] 必须是默认 warm：resolveTheme 对未知 id 回落首位。
    property string activeThemeId: "warm"

    // 旧 Canvas 主题 id → 新主题 id。旧主题全为浅色，迁移目标一律浅色款，
    // 不把老用户突然切进暗色界面。
    readonly property var legacyThemeMap: ({
        warmPaper: "warm", sunset: "warm", wheat: "warm",
        celadon: "jiangnan", mist: "jiangnan",
        sakura: "pink"
    })

    function migrateThemeId(themeId) {
        return legacyThemeMap[themeId] || themeId
    }

    function resolveTheme(themeId) {
        var target = migrateThemeId(themeId)
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === target) {
                return themes[i]
            }
        }
        return themes[0]
    }

    readonly property var palette: resolveTheme(activeThemeId)

    readonly property var themes: [
        {
            id: "warm", name: "暖色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/warm.png"),
            base: "#f3e3cf",
            surface: "#fffdf6", surfaceRaised: "#fbf5e9", surfaceSunken: "#f6ecdc",
            border: "#ead9bd", borderSubtle: "#f2e6cf",
            inkStrong: "#52422e", ink: "#6b573d", inkSoft: "#9c8266", inkMuted: "#b09a7d",
            accent: "#dc9550", accentStrong: "#c98240", accentSoft: "#f7e5c8", accentInk: "#9a6524",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#dc9550", "#9c8266", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#f1bd7e", focusRingArcMid: "#f4d3ab", focusRingArcEnd: "#f4c3bd",
            focusRingTrack: "#faf1e8",
            focusGlassCenter: "#fffefb", focusGlassEdge: "#fdf3ee", focusGlassShadow: "#e2b9a6",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#e8bda6",
            glassSidebar: Qt.rgba(1, 250 / 255, 242 / 255, 0.55),
            glassCard: Qt.rgba(1, 252 / 255, 246 / 255, 0.70),
            glassDialog: Qt.rgba(1, 252 / 255, 246 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.65)
        },
        {
            id: "pink", name: "粉色", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/pink.png"),
            base: "#efc4d0",
            surface: "#fffbfc", surfaceRaised: "#fdf3f6", surfaceSunken: "#f9e9ee",
            border: "#eed3dc", borderSubtle: "#f6e3e9",
            inkStrong: "#573f4b", ink: "#6d525f", inkSoft: "#a37f8f", inkMuted: "#b697a4",
            accent: "#e5638f", accentStrong: "#d1517d", accentSoft: "#fadbe6", accentInk: "#b03e66",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#e5638f", "#a37f8f", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#f3a0bc", focusRingArcMid: "#f8cbd9", focusRingArcEnd: "#f4c3bd",
            focusRingTrack: "#fbecf1",
            focusGlassCenter: "#fffcfd", focusGlassEdge: "#fdf0f4", focusGlassShadow: "#e3a8bd",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#edb7c8",
            glassSidebar: Qt.rgba(1, 242 / 255, 246 / 255, 0.55),
            glassCard: Qt.rgba(1, 250 / 255, 252 / 255, 0.70),
            glassDialog: Qt.rgba(1, 250 / 255, 252 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.65)
        },
        {
            id: "jiangnan", name: "烟雨江南", mode: "light",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/jiangnan.png"),
            base: "#dfe8e2",
            surface: "#fbfdfc", surfaceRaised: "#f2f8f5", surfaceSunken: "#e8f1ec",
            border: "#cfe0d7", borderSubtle: "#e0ece5",
            inkStrong: "#39473f", ink: "#54655c", inkSoft: "#84948a", inkMuted: "#9daba2",
            accent: "#5f9e85", accentStrong: "#4f8b73", accentSoft: "#dcece3", accentInk: "#3e7d63",
            success: "#4caf50", danger: "#b24f3d", dangerBorder: "#c46f5f", dangerSoft: "#b37562",
            chartColors: ["#5f9e85", "#84948a", "#c46f5f", "#9aa66b", "#6f91a6", "#b58aa0"],
            focusRingArcStart: "#8fc4ae", focusRingArcMid: "#c0ddd0", focusRingArcEnd: "#b7d3c8",
            focusRingTrack: "#eaf3ee",
            focusGlassCenter: "#fdfffe", focusGlassEdge: "#f0f7f3", focusGlassShadow: "#b6cfc2",
            focusGlassHighlight: "#ffffff", focusColonMuted: "#b9d2c6",
            glassSidebar: Qt.rgba(248 / 255, 252 / 255, 250 / 255, 0.55),
            glassCard: Qt.rgba(252 / 255, 254 / 255, 253 / 255, 0.70),
            glassDialog: Qt.rgba(252 / 255, 254 / 255, 253 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.65)
        },
        {
            id: "starry", name: "星空", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/starry.png"),
            base: "#12102a",
            surface: "#1b1936", surfaceRaised: "#232048", surfaceSunken: "#131126",
            border: "#3a3668", borderSubtle: "#2b2852",
            inkStrong: "#eceafb", ink: "#c6c2e0", inkSoft: "#8f8ab0", inkMuted: "#6f6a94",
            accent: "#8f7ff0", accentStrong: "#7b6ae0", accentSoft: "#35316b", accentInk: "#b9adff",
            success: "#6fcf73", danger: "#e0705a", dangerBorder: "#d97f6c", dangerSoft: "#cc8a76",
            chartColors: ["#8f7ff0", "#6f8fd8", "#d97f9c", "#7fb89a", "#c9a86a", "#9f8ad0"],
            focusRingArcStart: "#9b8cf5", focusRingArcMid: "#b6aaf8", focusRingArcEnd: "#d8a8c8",
            focusRingTrack: "#2a2650",
            focusGlassCenter: "#262254", focusGlassEdge: "#1d1a40", focusGlassShadow: "#0c0a20",
            focusGlassHighlight: "#4a4488", focusColonMuted: "#6a5fae",
            glassSidebar: Qt.rgba(20 / 255, 18 / 255, 42 / 255, 0.55),
            glassCard: Qt.rgba(32 / 255, 30 / 255, 62 / 255, 0.62),
            glassDialog: Qt.rgba(26 / 255, 24 / 255, 52 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.14)
        },
        {
            id: "rainy", name: "雨夜窗景", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/rainy.png"),
            base: "#0f1622",
            surface: "#17202e", surfaceRaised: "#1e2938", surfaceSunken: "#101823",
            border: "#33404f", borderSubtle: "#26313f",
            inkStrong: "#f0ebe2", ink: "#c9c3b6", inkSoft: "#8f8c84", inkMuted: "#6e6c66",
            accent: "#e8a34e", accentStrong: "#d9923c", accentSoft: "#3a3222", accentInk: "#f0b869",
            success: "#6fcf73", danger: "#e0705a", dangerBorder: "#d97f6c", dangerSoft: "#cc8a76",
            chartColors: ["#e8a34e", "#6f91b6", "#d97f6c", "#7fb89a", "#b9a0d0", "#8f8c84"],
            focusRingArcStart: "#efb268", focusRingArcMid: "#f4cfa0", focusRingArcEnd: "#d8a8a0",
            focusRingTrack: "#263143",
            focusGlassCenter: "#223040", focusGlassEdge: "#1a2534", focusGlassShadow: "#0b1119",
            focusGlassHighlight: "#3d4f63", focusColonMuted: "#8a7a5e",
            glassSidebar: Qt.rgba(16 / 255, 24 / 255, 38 / 255, 0.55),
            glassCard: Qt.rgba(26 / 255, 36 / 255, 52 / 255, 0.62),
            glassDialog: Qt.rgba(22 / 255, 31 / 255, 45 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.14)
        },
        {
            id: "moon", name: "月夜山影", mode: "dark",
            wallpaper: Qt.resolvedUrl("../resources/wallpapers/moon.png"),
            base: "#0d1626",
            surface: "#14202f", surfaceRaised: "#1b2a3c", surfaceSunken: "#0e1722",
            border: "#2e415a", borderSubtle: "#223349",
            inkStrong: "#e9eff7", ink: "#c0cbd9", inkSoft: "#8494a6", inkMuted: "#64768c",
            accent: "#7fa8d9", accentStrong: "#6a94c8", accentSoft: "#27374e", accentInk: "#a8c8ec",
            success: "#6fcf73", danger: "#e0705a", dangerBorder: "#d97f6c", dangerSoft: "#cc8a76",
            chartColors: ["#7fa8d9", "#8494a6", "#d97f6c", "#7fb89a", "#b9a0d0", "#c9a86a"],
            focusRingArcStart: "#8fb4de", focusRingArcMid: "#b6cee8", focusRingArcEnd: "#c8b8d8",
            focusRingTrack: "#223349",
            focusGlassCenter: "#1f3044", focusGlassEdge: "#182636", focusGlassShadow: "#0a121c",
            focusGlassHighlight: "#37516b", focusColonMuted: "#5f7e9e",
            glassSidebar: Qt.rgba(12 / 255, 22 / 255, 38 / 255, 0.55),
            glassCard: Qt.rgba(20 / 255, 32 / 255, 50 / 255, 0.62),
            glassDialog: Qt.rgba(16 / 255, 27 / 255, 42 / 255, 0.985),
            glassBorder: Qt.rgba(1, 1, 1, 0.14)
        }
    ]
```

- [ ] **Step 4: 验证通过** — Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
  Expected: PASS（ThemePalettes 全过；既有套件不受影响，因为本任务只新增属性）。

- [ ] **Step 5: Commit**

```bash
git add qml/Theme.qml tests/qml/tst_theme_palettes.qml
git commit -m "Theme新增六主题色板系统与旧id迁移"
```

---

### Task 3: BackgroundWallpaper 改 Image + 设置画廊与相关测试更新

**Files:**

- Rewrite: `qml/components/BackgroundWallpaper.qml`（整文件替换）
- Rewrite: `tests/qml/tst_background_wallpaper.qml`（整文件替换）
- Modify: `qml/components/SettingsDialog.qml:174,185,219-220`
- Modify: `qml/MainWindow.qml:182`
- Modify: `tests/qml/tst_settings_dialog.qml`（旧 id 替换）

**Interfaces:**

- Consumes: `Theme.themes`、`Theme.migrateThemeId(id)`（Task 2）。
- Produces: `BackgroundWallpaper { themeId: string; themeSource: var; readonly resolvedTheme: var }`，子项 objectName：`wallpaperBase`（兜底色 Rectangle）、`wallpaperImage`（Image）。

- [ ] **Step 1: 重写测试** — `tests/qml/tst_background_wallpaper.qml` 整文件替换为：

```qml
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
}
```

- [ ] **Step 2: 验证失败** — Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
  Expected: FAIL —— 旧组件无 `wallpaperImage`/`wallpaperBase`，`resolvedTheme` 走旧 `Theme.backgroundThemes`。

- [ ] **Step 3: 重写组件** — `qml/components/BackgroundWallpaper.qml` 整文件替换为：

```qml
import QtQuick
import ".."

// 背景壁纸层：主题壁纸图片 + 主题 base 兜底色（加载完成前/失败时可见）。
// 主题定义唯一来源 Theme.themes；测试可注入 themeSource。旧 id 由 Theme 迁移。
Item {
    id: root

    property string themeId: "warm"
    property var themeSource: Theme.themes

    readonly property var resolvedTheme: {
        var target = Theme.migrateThemeId(root.themeId)
        var themes = root.themeSource
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === target) {
                return themes[i]
            }
        }
        return themes[0]
    }

    Rectangle {
        objectName: "wallpaperBase"

        anchors.fill: parent
        color: root.resolvedTheme.base
    }

    Image {
        objectName: "wallpaperImage"

        anchors.fill: parent
        source: root.resolvedTheme.wallpaper || ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
    }
}
```

- [ ] **Step 4: 设置画廊与主窗兜底 id 更新**
  - `qml/components/SettingsDialog.qml:174`：`model: Theme.backgroundThemes` → `model: Theme.themes`
  - `qml/components/SettingsDialog.qml:185`：`: themeCell.modelData.id === "warmPaper"` → `: themeCell.modelData.id === "warm"`
  - `qml/components/SettingsDialog.qml:219-220`（迷你磨砂条，让每格预览显示**该主题**的玻璃观感而非当前主题的）：
    `color: Theme.glassCard` → `color: themeCell.modelData.glassCard`；
    `border.color: Theme.glassBorder` → `border.color: themeCell.modelData.glassBorder`
  - `qml/MainWindow.qml:182`：`: "warmPaper"` → `: "warm"`

- [ ] **Step 5: 更新设置弹窗测试** — `tests/qml/tst_settings_dialog.qml` 中做替换（仅这两个旧 id 在该文件中只作主题 id 使用）：
  - 全部 `"warmPaper"` → `"warm"`（现第 18、38、86、106、293 行）
  - 全部 `"celadon"` → `"jiangnan"`（现第 80、93 行）
  - 对应 objectName 查找串（如 `settingsThemeCell-warmPaper`）若为拼接式则无需改；若有字面量同步替换。

- [ ] **Step 6: 验证通过** — Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
  Expected: PASS。注意 `tst_theme_tokens.qml` 的 `test_backgroundThemesDefinitions` 仍引用旧数组——旧数组本任务未删，仍应通过。

- [ ] **Step 7: Commit**

```bash
git add qml/components/BackgroundWallpaper.qml qml/components/SettingsDialog.qml qml/MainWindow.qml tests/qml/tst_background_wallpaper.qml tests/qml/tst_settings_dialog.qml
git commit -m "壁纸层改为主题图片渲染并更新设置画廊"
```

---

### Task 4: 色板接线：全部 token 随主题切换 + 删除旧主题定义

**Files:**

- Modify: `qml/Theme.qml`（token 改绑 palette；删除 `backgroundThemes` 数组）
- Modify: `qml/MainWindow.qml`（activeThemeId 绑定 + 启动迁移写回）
- Rewrite: `tests/qml/tst_theme_tokens.qml`（整文件替换）

**Interfaces:**

- Consumes: Task 2 的 `palette`/`migrateThemeId`；Task 3 已把所有旧 id 使用点换新。
- Produces: `Theme.<token>` 全部随 `Theme.activeThemeId` 变化；`Theme.backgroundThemes` 不复存在。

- [ ] **Step 1: 重写 token 测试** — `tests/qml/tst_theme_tokens.qml` 整文件替换为：

```qml
import QtQuick
import QtTest
import "../../qml"

// 验证 Theme 单例 token 绑定当前主题色板，且随 activeThemeId 切换。
TestCase {
    name: "ThemeTokens"

    function init() {
        Theme.activeThemeId = "warm"
    }

    function cleanupTestCase() {
        Theme.activeThemeId = "warm"
    }

    function test_defaultWarmTokens() {
        verify(Qt.colorEqual(Theme.accent, "#dc9550"), "accent 取值不对")
        verify(Qt.colorEqual(Theme.accentStrong, "#c98240"), "accentStrong 取值不对")
        verify(Qt.colorEqual(Theme.surface, "#fffdf6"), "surface 取值不对")
        verify(Qt.colorEqual(Theme.border, "#ead9bd"), "border 取值不对")
        verify(Qt.colorEqual(Theme.ink, "#6b573d"), "ink 取值不对")
        verify(Qt.colorEqual(Theme.danger, "#b24f3d"), "danger 取值不对")
        verify(Qt.colorEqual(Theme.dangerSoft, "#b37562"), "dangerSoft 取值不对")
        verify(Qt.colorEqual(Theme.shadow, "#000000"), "shadow 应保持纯黑")
    }

    function test_tokensFollowThemeSwitch() {
        Theme.activeThemeId = "starry"
        verify(Qt.colorEqual(Theme.accent, "#8f7ff0"), "starry accent 未生效")
        verify(Qt.colorEqual(Theme.inkStrong, "#eceafb"), "starry inkStrong 未生效")
        verify(Qt.colorEqual(Theme.surface, "#1b1936"), "starry surface 未生效")
        verify(Qt.colorEqual(Theme.success, "#6fcf73"), "暗色 success 应提亮")
        Theme.activeThemeId = "warm"
        verify(Qt.colorEqual(Theme.accent, "#dc9550"), "切回 warm 未复原")
    }

    function test_glassTokensFollowTheme() {
        verify(Qt.colorEqual(Theme.glassSidebar, Qt.rgba(1, 250 / 255, 242 / 255, 0.55)),
               "warm glassSidebar 取值不对")
        Theme.activeThemeId = "moon"
        verify(Qt.colorEqual(Theme.glassCard, Qt.rgba(20 / 255, 32 / 255, 50 / 255, 0.62)),
               "moon glassCard 取值不对")
        verify(Qt.colorEqual(Theme.glassBorder, Qt.rgba(1, 1, 1, 0.14)),
               "暗色 glassBorder 取值不对")
    }

    function test_chartColorsFollowTheme() {
        compare(Theme.chartColors.length, 6)
        verify(Qt.colorEqual(Theme.chartColors[0], "#dc9550"), "warm chartColors[0] 不对")
        Theme.activeThemeId = "rainy"
        verify(Qt.colorEqual(Theme.chartColors[0], "#e8a34e"), "rainy chartColors[0] 不对")
    }

    function test_focusBreakAccentIsChartColor3() {
        verify(Qt.colorEqual(Theme.focusBreakAccent, Theme.chartColors[3]))
        Theme.activeThemeId = "starry"
        verify(Qt.colorEqual(Theme.focusBreakAccent, Theme.chartColors[3]))
    }

    function test_focusRingTokensFollowTheme() {
        verify(Qt.colorEqual(Theme.focusRingArcStart, "#f1bd7e"), "warm arcStart 不对")
        Theme.activeThemeId = "moon"
        verify(Qt.colorEqual(Theme.focusRingArcStart, "#8fb4de"), "moon arcStart 不对")
        verify(Qt.colorEqual(Theme.focusRingTrack, "#223349"), "moon track 不对")
    }

    function test_scaleTokens() {
        compare(Theme.fontMd, 13)
        compare(Theme.fontXxl, 24)
        compare(Theme.space16, 16)
        compare(Theme.radiusMd, 6)
    }

    function test_fontFamilyTokens() {
        compare(Theme.fontFamilyClock, "Space Grotesk")
        compare(Theme.fontFamilyData, "Bricolage Grotesque")
    }
}
```

- [ ] **Step 2: 验证失败** — Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
  Expected: FAIL —— token 仍是旧固定值（如 accent #d4a574）。

- [ ] **Step 3: Theme token 改绑 palette** — `qml/Theme.qml`：把第 7-44 行（surface 到 shadow）与第 74-103 行（chartColors 到 glassBorder）的所有**颜色/图表声明**替换为 palette 绑定；字号/字族/间距/圆角（45-73 行中的非颜色部分）保持不动；`shadow` 保持固定值。替换后的声明块：

```qml
    // —— 以下颜色 token 全部绑定当前主题色板（palette）；属性名保持不变，
    // 存量组件零改动跟随换色。palette 定义见文件下方主题系统 v2。——
    readonly property color surface: palette.surface
    readonly property color surfaceRaised: palette.surfaceRaised
    readonly property color surfaceSunken: palette.surfaceSunken

    readonly property color border: palette.border
    readonly property color borderSubtle: palette.borderSubtle

    readonly property color inkStrong: palette.inkStrong
    readonly property color ink: palette.ink
    readonly property color inkSoft: palette.inkSoft
    readonly property color inkMuted: palette.inkMuted

    readonly property color accent: palette.accent
    readonly property color accentStrong: palette.accentStrong
    readonly property color accentSoft: palette.accentSoft
    readonly property color accentInk: palette.accentInk

    readonly property color success: palette.success
    readonly property color danger: palette.danger
    readonly property color dangerBorder: palette.dangerBorder
    readonly property color dangerSoft: palette.dangerSoft

    // 投影恒为纯黑；透明度由各效果自身属性控制，不随主题。
    readonly property color shadow: "#000000"

    readonly property var chartColors: palette.chartColors
    readonly property color focusBreakAccent: chartColors[3]

    readonly property color focusRingArcStart: palette.focusRingArcStart
    readonly property color focusRingArcMid: palette.focusRingArcMid
    readonly property color focusRingArcEnd: palette.focusRingArcEnd
    readonly property color focusRingTrack: palette.focusRingTrack
    readonly property color focusGlassCenter: palette.focusGlassCenter
    readonly property color focusGlassEdge: palette.focusGlassEdge
    readonly property color focusGlassShadow: palette.focusGlassShadow
    readonly property color focusGlassHighlight: palette.focusGlassHighlight
    readonly property color focusColonMuted: palette.focusColonMuted

    readonly property color glassSidebar: palette.glassSidebar
    readonly property color glassCard: palette.glassCard
    readonly property color glassDialog: palette.glassDialog
    readonly property color glassBorder: palette.glassBorder
```

  同时**整块删除** `backgroundThemes` 数组及其注释（原 105-133 行）。

- [ ] **Step 4: MainWindow 接线** — `qml/MainWindow.qml` 在 `BackgroundWallpaper { ... }` 块之前插入：

```qml
    // 设置值（可能是旧 id）迁移后驱动全局色板。
    Binding {
        target: Theme
        property: "activeThemeId"
        value: root.appSettingsRef
            ? Theme.migrateThemeId(root.appSettingsRef.backgroundTheme)
            : "warm"
    }
```

  并在 MainWindow 根元素上新增（根元素当前没有 Component.onCompleted）：

```qml
    Component.onCompleted: {
        // 旧主题 id 只在启动时迁移写回一次，此后设置里存的都是新 id。
        if (root.appSettingsRef) {
            var migrated = Theme.migrateThemeId(root.appSettingsRef.backgroundTheme)
            if (migrated !== root.appSettingsRef.backgroundTheme) {
                root.appSettingsRef.backgroundTheme = migrated
            }
        }
    }
```

- [ ] **Step 5: 全量 QML 测试** — Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
  Expected: PASS。`tst_glass_components` 等对玻璃/强调色的断言全部走 `Theme.<token>` 引用，值变化自动跟随。若有测试断言旧字面量色值（如 #d4a574），逐个改为断言 Theme token 引用或新 warm 值。

- [ ] **Step 6: Commit**

```bash
git add qml/Theme.qml qml/MainWindow.qml tests/qml/tst_theme_tokens.qml
git commit -m "全套UI色板随主题切换并移除旧Canvas主题定义"
```

---

### Task 5: 全量回归 + 实机六主题验证

**Files:**

- Modify: 无预期改动；本任务只验证与修偏差。

**Interfaces:**

- Consumes: Task 1-4 全部产物。

- [ ] **Step 1: 全部测试** — Run: `cmake --build build -j8 && ctest --test-dir build --output-on-failure`
  Expected: 全部套件 PASS（PomodoroTodoTests、CountdownServiceTests、FontAssetsTests、WallpaperAssetsTests、PomodoroTodoQmlTests）。

- [ ] **Step 2: 实机验证** — 构建并启动 app（目标名 `PomodoroTodo`：`open build/PomodoroTodo.app` 或 `./build/PomodoroTodo.app/Contents/MacOS/PomodoroTodo`），打开设置 → 背景主题画廊：
  - 画廊显示六款缩略图（真实壁纸缩略 + 各自玻璃条预览）；
  - 逐一点击六款：壁纸、侧栏玻璃、任务卡、按钮强调色、文字颜色即时切换；
  - 三款暗色主题：文字为浅色、玻璃为暗色、统计图表配色跟随；
  - 专注页：计时环渐变与玻璃盘随主题变化；
  - 重启 app：主题保持所选；若手工把设置里的 `appearance/backgroundTheme` 改回 `warmPaper` 再启动，应自动迁移为 `warm` 且界面正常。

- [ ] **Step 3: 视觉基准比对** — 与 Artifact 设计稿（「番茄todo · 背景主题设计稿」）逐款对照，若观感偏差（如暗色卡片太透、强调色不显眼），只调 Theme.qml 中对应主题的 token 值，改后重跑 `ctest --test-dir build -R PomodoroTodoQmlTests`（若调整了被测色值需同步测试）。

- [ ] **Step 4: 收尾提交（如有微调）**

```bash
git add -A
git commit -m "主题实机验证与色板微调"
```
