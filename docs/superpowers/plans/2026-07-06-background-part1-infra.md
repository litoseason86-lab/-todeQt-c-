# 背景主题 · 计划一（基础设施 + 可切换壁纸）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地壁纸层、玻璃令牌、设置弹窗与侧栏入口——壁纸可切换、即点即切即持久化；主内容区（`mainContentBackground`）本阶段**保持现状不动**（声明过的过渡状态）。

**Architecture:** AppSettings 新增 `backgroundTheme` 字符串属性（不校验，回落收敛在 QML）；Theme.qml 集中玻璃令牌与 6 张壁纸定义（唯一来源）；新组件 BackgroundWallpaper（Canvas 渐变 + 噪点）铺 MainWindow 最底层；Sidebar 玻璃化并新增「设置」条目；新组件 SettingsDialog 画廊复用 BackgroundWallpaper 小实例。

**Tech Stack:** Qt 6.9 / C++17 / QML / QSettings / Canvas / Qt Test + qmltestrunner

## Global Constraints

- 注释、提交说明一律中文；注释解释"为什么/边界"（AGENTS.md）。
- 构建：`cmake --build build`；Qt 前缀 `/Users/zerionlito/Qt/6.9.0/macos`；**不得改 build/**。
- C++ 单测：`./build/PomodoroTodoTests <测试函数名>`；QML 单文件：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`。
- QML 测试纪律：**不断言 `visible === true`**（项目既有教训）；颜色 alpha 等浮点用近似断言（`< 0.01` / `> 0.99`），不裸 compare。
- 单文件验收 = qmltestrunner 连续 2 次全绿。
- 新组件 qmllint 零警告：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <文件>`。
- 玻璃令牌定稿值：`glassSidebar = Qt.rgba(1,1,252/255,0.55)`、`glassCard = Qt.rgba(1,1,250/255,0.68)`、`glassDialog = Qt.rgba(1,254/255,249/255,0.94)`、`glassBorder = Qt.rgba(1,1,1,0.65)`。
- qrc 注册随组件创建任务一起提交（Task 3 / Task 6），组件文件与注册行同一提交落地，避免 rcc 引用缺失文件。

---

### Task 1: AppSettings 新增 backgroundTheme 属性

**Files:**

- Modify: `src/services/AppSettings.h`
- Modify: `src/services/AppSettings.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Produces: `Q_PROPERTY(QString backgroundTheme ...)`，QSettings 键 `appearance/backgroundTheme`，默认 `"warmPaper"`；信号 `backgroundThemeChanged()`。后续任务经上下文属性 `appSettings.backgroundTheme` 读写。

- [x] **Step 1: 写失败测试**

在 `tests/ServiceTests.cpp` 私有槽声明区、`void appSettingsRolloverIgnoredDateRoundTrip();`（约 376 行）之后加：

```cpp
    void appSettingsBackgroundThemeDefaultAndRoundTrip();
```

在 `appSettingsRolloverIgnoredDateRoundTrip()` 实现（约 508-525 行）之后加：

```cpp
void ServiceTests::appSettingsBackgroundThemeDefaultAndRoundTrip()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    {
        AppSettings settings(path);
        // 默认必须是暖纸：与 Theme.backgroundThemes 首位的回落约定一致。
        QCOMPARE(settings.backgroundTheme(), QStringLiteral("warmPaper"));

        QSignalSpy spy(&settings, &AppSettings::backgroundThemeChanged);
        settings.setBackgroundTheme(QStringLiteral("celadon"));
        QCOMPARE(settings.backgroundTheme(), QStringLiteral("celadon"));
        QCOMPARE(spy.count(), 1);

        // 同值写入不重复发信号（与其它偏好一致）。
        settings.setBackgroundTheme(QStringLiteral("celadon"));
        QCOMPARE(spy.count(), 1);
    }

    // 重建实例验证持久化。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.backgroundTheme(), QStringLiteral("celadon"));
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译失败，`no member named 'backgroundTheme'`。

- [x] **Step 3: 最小实现**

`src/services/AppSettings.h`——Q_PROPERTY 区（16 行后）加：

```cpp
    Q_PROPERTY(QString backgroundTheme READ backgroundTheme WRITE setBackgroundTheme NOTIFY backgroundThemeChanged)
```

public 区（31 行后）加：

```cpp
    QString backgroundTheme() const;
    void setBackgroundTheme(const QString& themeId);
```

signals 区（38 行后）加：

```cpp
    void backgroundThemeChanged();
```

`src/services/AppSettings.cpp`——匿名命名空间（8 行后）加：

```cpp
const auto kBackgroundThemeKey = QStringLiteral("appearance/backgroundTheme");
```

文件末尾加：

```cpp
QString AppSettings::backgroundTheme() const
{
    // 只存取字符串、不校验合法性：主题定义的唯一来源在 Theme.qml，
    // C++ 若再维护一份合法 id 列表就是两处维护，新增壁纸漏改其一会静默失效。
    // 未知 id 的回落由 BackgroundWallpaper 负责（全应用唯一回落点）。
    return m_settings->value(kBackgroundThemeKey, QStringLiteral("warmPaper")).toString();
}

void AppSettings::setBackgroundTheme(const QString& themeId)
{
    if (backgroundTheme() == themeId) {
        return;
    }
    m_settings->setValue(kBackgroundThemeKey, themeId);
    m_settings->sync();
    emit backgroundThemeChanged();
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cmake --build build && ./build/PomodoroTodoTests appSettingsBackgroundThemeDefaultAndRoundTrip`
Expected: PASS（1 passed）。

- [x] **Step 5: 提交**

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp tests/ServiceTests.cpp
git commit -m "AppSettings 新增背景主题偏好 backgroundTheme"
```

---

### Task 2: Theme.qml 玻璃令牌 + 壁纸主题定义

**Files:**

- Modify: `qml/Theme.qml`
- Test: `tests/qml/tst_theme_tokens.qml`

**Interfaces:**

- Produces: `Theme.glassSidebar/glassCard/glassDialog/glassBorder`（color）；`Theme.backgroundThemes`（var 数组，首位必须是 `warmPaper`，每项 `{id, name, base, blobs:[{cx,cy,rx,ry,color}×3]}`）。

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_theme_tokens.qml` 的 `test_chartColorsIsArray()` 之后加：

```qml
    function test_glassTokens() {
        verify(Qt.colorEqual(Theme.glassSidebar, Qt.rgba(1, 1, 252 / 255, 0.55)), "glassSidebar 取值不对")
        verify(Qt.colorEqual(Theme.glassCard, Qt.rgba(1, 1, 250 / 255, 0.68)), "glassCard 取值不对")
        verify(Qt.colorEqual(Theme.glassDialog, Qt.rgba(1, 254 / 255, 249 / 255, 0.94)), "glassDialog 取值不对")
        verify(Qt.colorEqual(Theme.glassBorder, Qt.rgba(1, 1, 1, 0.65)), "glassBorder 取值不对")
    }

    function test_backgroundThemesDefinitions() {
        var themes = Theme.backgroundThemes
        compare(themes.length, 6)
        // 回落约定：首位必须是默认暖纸，BackgroundWallpaper 未知 id 回落 themes[0]。
        compare(themes[0].id, "warmPaper")

        var seen = {}
        for (var i = 0; i < themes.length; i++) {
            var t = themes[i]
            verify(!seen[t.id], "id 重复: " + t.id)
            seen[t.id] = true
            verify(String(t.name).length > 0, t.id + " 缺名称")
            compare(String(t.base).charAt(0), "#")
            compare(t.blobs.length, 3)
            for (var j = 0; j < 3; j++) {
                var b = t.blobs[j]
                verify(b.cx >= 0 && b.cy >= 0, t.id + " 光晕坐标非法")
                verify(b.rx > 0 && b.ry > 0, t.id + " 光晕半径非法")
                compare(String(b.color).charAt(0), "#")
            }
        }
    }
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`
Expected: FAIL（`glassSidebar` 未定义 / `backgroundThemes` undefined）。

- [x] **Step 3: 最小实现**

在 `qml/Theme.qml` 的 `focusBreakAccent` 定义之后（文件末尾 `}` 之前）加：

```qml
    // —— 玻璃令牌（背景主题：磨砂面板，均衡档定稿）——
    // 用"白 + alpha"而非灰色：面板叠在彩色壁纸上，白基半透明才能透出壁纸色相。
    readonly property color glassSidebar: Qt.rgba(1, 1, 252 / 255, 0.55)
    readonly property color glassCard: Qt.rgba(1, 1, 250 / 255, 0.68)
    readonly property color glassDialog: Qt.rgba(1, 254 / 255, 249 / 255, 0.94)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.65)

    // —— 背景壁纸主题定义（唯一来源：画廊缩略图与壁纸层都读这里）——
    // 首位必须是默认暖纸：BackgroundWallpaper 对未知 id 回落 backgroundThemes[0]。
    // blobs 的 cx/cy/rx/ry 是相对窗口宽/高的比例，光晕由中心色淡出到全透明。
    readonly property var backgroundThemes: [
        { id: "warmPaper", name: "暖纸", base: "#faf2e4", blobs: [
            { cx: 0.18, cy: 0.15, rx: 0.90, ry: 0.70, color: "#fdf3e0" },
            { cx: 0.85, cy: 0.25, rx: 0.80, ry: 0.60, color: "#f6e2c8" },
            { cx: 0.55, cy: 0.95, rx: 1.00, ry: 0.80, color: "#f2ded2" } ] },
        { id: "sunset", name: "暮橙", base: "#fdeadb", blobs: [
            { cx: 0.15, cy: 0.10, rx: 0.85, ry: 0.70, color: "#ffe3c2" },
            { cx: 0.88, cy: 0.30, rx: 0.90, ry: 0.65, color: "#fbc9ad" },
            { cx: 0.50, cy: 1.00, rx: 1.10, ry: 0.75, color: "#f9d5c4" } ] },
        { id: "celadon", name: "青瓷", base: "#edf5ee", blobs: [
            { cx: 0.20, cy: 0.12, rx: 0.85, ry: 0.65, color: "#ddefe2" },
            { cx: 0.85, cy: 0.35, rx: 0.80, ry: 0.70, color: "#cde7dd" },
            { cx: 0.45, cy: 1.00, rx: 1.00, ry: 0.80, color: "#e3f1e4" } ] },
        { id: "mist", name: "晨雾", base: "#f0eff7", blobs: [
            { cx: 0.18, cy: 0.15, rx: 0.85, ry: 0.65, color: "#e4e4f4" },
            { cx: 0.85, cy: 0.28, rx: 0.85, ry: 0.70, color: "#d7e2f3" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#ebe4f2" } ] },
        { id: "sakura", name: "樱粉", base: "#fdf0f1", blobs: [
            { cx: 0.20, cy: 0.12, rx: 0.85, ry: 0.65, color: "#fbdbe2" },
            { cx: 0.85, cy: 0.30, rx: 0.85, ry: 0.70, color: "#f8e2ea" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#fceaea" } ] },
        { id: "wheat", name: "麦浪", base: "#fbf5e2", blobs: [
            { cx: 0.18, cy: 0.12, rx: 0.85, ry: 0.65, color: "#f8edc6" },
            { cx: 0.85, cy: 0.32, rx: 0.85, ry: 0.70, color: "#f3e3b4" },
            { cx: 0.50, cy: 1.00, rx: 1.00, ry: 0.80, color: "#f9f0d2" } ] }
    ]
```

- [x] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`（连续跑 2 次）
Expected: 全绿 ×2。

- [x] **Step 5: 提交**

```bash
git add qml/Theme.qml tests/qml/tst_theme_tokens.qml
git commit -m "Theme 新增玻璃令牌与六张壁纸主题定义"
```

---

### Task 3: BackgroundWallpaper 组件 + qrc 注册

**Files:**

- Create: `qml/components/BackgroundWallpaper.qml`
- Modify: `resources/qml.qrc`
- Test: `tests/qml/tst_background_wallpaper.qml`（新建）

**Interfaces:**

- Consumes: `Theme.backgroundThemes`（Task 2）。
- Produces: `BackgroundWallpaper { property string themeId; readonly property var resolvedTheme; property alias paintCount }`——Task 4（MainWindow 壁纸层）与 Task 6（画廊缩略图）都实例化它。

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_background_wallpaper.qml`：

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
        // 配置文件手改/将来删壁纸留下的陈旧 id，不应让背景开天窗。
        wallpaper.themeId = "no-such-theme"
        compare(wallpaper.resolvedTheme.id, "warmPaper")
    }

    function test_themeChangeTriggersRepaint() {
        // 先等首帧真实绘制，再验证切主题带来增量重绘——守护 onThemeIdChanged: requestPaint()。
        tryVerify(function() { return wallpaper.paintCount > 0 }, 3000)
        var before = wallpaper.paintCount
        wallpaper.themeId = "sunset"
        tryVerify(function() { return wallpaper.paintCount > before }, 3000)
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`
Expected: FAIL（BackgroundWallpaper 不存在）。

- [x] **Step 3: 实现组件**

新建 `qml/components/BackgroundWallpaper.qml`：

```qml
import QtQuick
import ".."

// 背景壁纸层：底色 + 三个椭圆径向光晕 + 噪点颗粒。
// 主题定义唯一来源是 Theme.backgroundThemes；未知 id 在这里回落首位暖纸——
// 这是全应用唯一的回落点，AppSettings 侧刻意不做校验（避免两处维护主题列表）。
Item {
    id: root

    property string themeId: "warmPaper"
    property alias paintCount: canvas.paintCount

    readonly property var resolvedTheme: {
        var themes = Theme.backgroundThemes;
        for (var i = 0; i < themes.length; i++) {
            if (themes[i].id === root.themeId) {
                return themes[i];
            }
        }
        return themes[0];
    }

    // 切主题必须显式触发重绘：Canvas 不会因为 JS 数据变化自动重画。
    onThemeIdChanged: canvas.requestPaint()

    Canvas {
        id: canvas

        property int paintCount: 0

        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            if (width <= 0 || height <= 0) {
                return; // 初始化瞬间可能是零尺寸，画了也是废帧。
            }

            var ctx = getContext("2d");
            var theme = root.resolvedTheme;

            ctx.clearRect(0, 0, width, height);
            ctx.fillStyle = theme.base;
            ctx.fillRect(0, 0, width, height);

            for (var i = 0; i < theme.blobs.length; i++) {
                var blob = theme.blobs[i];
                // createRadialGradient 只支持正圆：先把坐标系按椭圆比例拉伸，再画单位圆。
                ctx.save();
                ctx.translate(blob.cx * width, blob.cy * height);
                ctx.scale(blob.rx * width, blob.ry * height);
                var center = Qt.color(blob.color);
                var gradient = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
                gradient.addColorStop(0, blob.color);
                // 淡出到"同色 alpha 0"而非透明白/黑：异色插值会出现脏边。
                gradient.addColorStop(1, Qt.rgba(center.r, center.g, center.b, 0));
                ctx.fillStyle = gradient;
                ctx.beginPath();
                ctx.arc(0, 0, 1, 0, Math.PI * 2);
                ctx.fill();
                ctx.restore();
            }

            paintCount += 1;
        }
    }

    Image {
        // 纸感噪点随壁纸整层走（MainWindow 里的旧噪点层在计划二移除，避免双重颗粒）。
        anchors.fill: parent
        opacity: 0.03
        fillMode: Image.Tile
        source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='noise'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23noise)'/></svg>"
    }
}
```

- [x] **Step 4: qrc 注册**

在 `resources/qml.qrc` 的 `<file alias="qml/components/Sidebar.qml">` 行之前加：

```xml
        <file alias="qml/components/BackgroundWallpaper.qml">../qml/components/BackgroundWallpaper.qml</file>
```

- [x] **Step 5: 跑测试确认通过（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_background_wallpaper.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/BackgroundWallpaper.qml`
Expected: 零警告。

- [x] **Step 6: 提交**

```bash
git add qml/components/BackgroundWallpaper.qml resources/qml.qrc tests/qml/tst_background_wallpaper.qml
git commit -m "新增背景壁纸组件并注册资源"
```

---

### Task 4: MainWindow 接入壁纸层

**Files:**

- Modify: `qml/MainWindow.qml`
- Test: `tests/qml/tst_mainwindow_ui_optimization.qml`

**Interfaces:**

- Consumes: `BackgroundWallpaper`（Task 3）、`appSettings.backgroundTheme`（Task 1，经既有 `root.appSettingsRef`）。
- Produces: objectName `backgroundWallpaperLayer`，themeId 绑定设置项。

- [x] **Step 1: 写失败测试**

`tests/qml/tst_mainwindow_ui_optimization.qml` 目前**没有** appSettings mock（MainWindow 的 `appSettingsRef` 一直是 null 守卫分支）。在 focusTimer mock 之后加一个完整 mock（属性齐全，避免 FocusView/TodayTaskView 读到 undefined）：

```qml
    QtObject {
        id: appSettings

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
        property string rolloverIgnoredDate: ""
        property string backgroundTheme: "celadon"
    }
```

测试函数（加到文件已有测试之后；MainWindow 实例 id 为 `mainWindow`，见 166 行）：

```qml
    function test_wallpaperLayerFollowsSettings() {
        var wallpaper = findChild(mainWindow, "backgroundWallpaperLayer")
        verify(wallpaper)
        compare(wallpaper.themeId, "celadon")
        compare(wallpaper.resolvedTheme.id, "celadon")

        appSettings.backgroundTheme = "sunset"
        compare(wallpaper.themeId, "sunset")
        appSettings.backgroundTheme = "celadon"
    }
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`
Expected: 新测试 FAIL（findChild 返回 null）；**同时确认既有测试没有因为新增 appSettings mock 变红**——若有，修 mock 属性而不是测试。

- [x] **Step 3: 实现**

在 `qml/MainWindow.qml` 的 `RowLayout {`（约 163 行）之前加：

```qml
    BackgroundWallpaper {
        objectName: "backgroundWallpaperLayer"

        anchors.fill: parent
        // 声明在最前 = 画在最底层，侧栏与内容作为后声明的兄弟自然叠在其上。
        themeId: root.appSettingsRef ? root.appSettingsRef.backgroundTheme : "warmPaper"
    }
```

（`import "components"` 已存在，无需新增。）

- [x] **Step 4: 跑测试确认通过（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`（×2）
Expected: 全绿 ×2。

- [x] **Step 5: 提交**

```bash
git add qml/MainWindow.qml tests/qml/tst_mainwindow_ui_optimization.qml
git commit -m "主窗口接入壁纸层并绑定主题设置"
```

---

### Task 5: Sidebar 玻璃化 + 「设置」条目

**Files:**

- Modify: `qml/components/Sidebar.qml`
- Test: `tests/qml/tst_sidebar_ui_optimization.qml`

**Interfaces:**

- Consumes: `Theme.glassSidebar`（Task 2）。
- Produces: `signal settingsRequested`；objectName `sidebarItem-设`。Task 6 在 MainWindow 接线。

- [x] **Step 1: 写失败测试**

在 `tests/qml/tst_sidebar_ui_optimization.qml` 中加（SignalSpy 放 Sidebar 实例之后，测试函数放已有函数之后）：

```qml
    SignalSpy {
        id: settingsSpy

        target: sidebar
        signalName: "settingsRequested"
    }

    function test_glassSurface() {
        verify(Qt.colorEqual(sidebar.color, Theme.glassSidebar), "侧栏底色应为玻璃令牌")
        // 渐变必须移除：仅断言 color 相等挡不住残留 gradient 盖在色值上。
        // 这里用红绿流程验证断言本身：本步先跑（红，因 gradient 仍在），实现后转绿。
        verify(!sidebar.gradient, "侧栏渐变应已移除")
    }

    function test_itemIdleIsWhiteBasedTransparent() {
        // 白基透明（RGB=1、alpha=0）：与 hover 白插值只动 alpha、不经过灰，守住防灰闪约束。
        verify(sidebar.sidebarItemIdleColor.a < 0.01, "idle 底色应全透明")
        verify(sidebar.sidebarItemIdleColor.r > 0.99, "idle 底色必须白基")
        verify(sidebar.sidebarItemIdleBorderColor.a < 0.01, "idle 边框应全透明")
        verify(Qt.colorEqual(sidebar.sidebarItemHoverColor, Qt.rgba(1, 1, 1, 0.45)), "hover 应为半透明白")
    }

    function test_settingsEntryEmitsSignal() {
        var item = findChild(sidebar, "sidebarItem-设")
        verify(item, "设置条目应存在")
        settingsSpy.clear()
        item.clicked()
        compare(settingsSpy.count, 1)
    }
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`
Expected: 3 个新测试 FAIL（signalName 不存在会直接报错，也算红）。**记录 `!sidebar.gradient` 此时的失败信息**——若它意外通过（说明带渐变时 gradient 读数也是 falsy），把该断言替换为 `verify(Qt.colorEqual(sidebar.color, Theme.glassSidebar))` 加实现侧删除渐变后的人工确认，并在测试注释里说明原因。

- [x] **Step 3: 实现**

`qml/components/Sidebar.qml`：

1. 删掉 9-10 行两个渐变色属性和 21-33 行整个 `gradient: Gradient { ... }` 块；
2. 在根 Rectangle 加 `color: Theme.glassSidebar`；
3. 把 11-17 行的 idle/hover 属性组连注释一起替换为：

```qml
    // 玻璃侧栏上的条目默认态要"隐形"才能透出壁纸；但不能用 Qt 的 transparent（黑基透明）：
    // hover 退场的 ColorAnimation 会在黑↔白之间插出灰闪（这是本文件的老约束）。
    // 白基透明（RGB 恒白、只动 alpha）与 hover 白插值时不经过灰，隐形与防灰闪兼得。
    readonly property color sidebarItemIdleColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemIdleBorderColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemHoverColor: Qt.rgba(1, 1, 1, 0.45)
    readonly property color sidebarItemHoverBorderColor: Theme.border
```

4. 在 `signal dataExportRequested` 之后加 `signal settingsRequested`；
5. 在「数据导出」SidebarItem 之后、「三阶段」Text 之前加：

```qml
        SidebarItem {
            text: "设置"
            marker: "设"
            isActive: false
            onClicked: root.settingsRequested()
        }
```

- [x] **Step 4: 跑测试确认通过（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/Sidebar.qml`
Expected: 不多于改动前的警告数（该文件是既有组件，只要求不新增警告）。

- [x] **Step 5: 提交**

```bash
git add qml/components/Sidebar.qml tests/qml/tst_sidebar_ui_optimization.qml
git commit -m "侧栏玻璃化并新增设置入口条目"
```

---

### Task 6: SettingsDialog 组件 + qrc + MainWindow 接线

**Files:**

- Create: `qml/components/SettingsDialog.qml`
- Modify: `resources/qml.qrc`
- Modify: `qml/MainWindow.qml`
- Test: `tests/qml/tst_settings_dialog.qml`（新建）

**Interfaces:**

- Consumes: `Theme.backgroundThemes`、玻璃令牌（Task 2）、`BackgroundWallpaper`（Task 3）、`Sidebar.settingsRequested`（Task 5）。
- Produces: `SettingsDialog { property var appSettingsRef; function selectTheme(themeId) }`；objectName：`settingsDialogPanel`、`settingsThemeRepeater`、`settingsThemeCell-<id>`、`settingsThemeThumb-<id>`。

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_settings_dialog.qml`：

```qml
import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "SettingsDialog"
    when: windowShown
    width: 700
    height: 520

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warmPaper"
    }

    SettingsDialog {
        id: dialog

        appSettingsRef: appSettingsMock
    }

    function init() {
        appSettingsMock.backgroundTheme = "warmPaper"
        dialog.appSettingsRef = appSettingsMock
        dialog.close()
        wait(20)
    }

    function test_galleryShowsAllThemes() {
        dialog.open()
        wait(20)
        var repeater = findChild(dialog, "settingsThemeRepeater")
        verify(repeater)
        compare(repeater.count, 6)
    }

    function test_clickThumbWritesThemeId() {
        dialog.open()
        wait(20)
        var thumb = findChild(dialog, "settingsThemeThumb-celadon")
        verify(thumb)
        mouseClick(thumb)
        compare(appSettingsMock.backgroundTheme, "celadon")
    }

    function test_selectedFollowsSettings() {
        dialog.open()
        wait(20)
        var warmCell = findChild(dialog, "settingsThemeCell-warmPaper")
        var celadonCell = findChild(dialog, "settingsThemeCell-celadon")
        verify(warmCell)
        verify(celadonCell)
        verify(warmCell.selected)
        verify(!celadonCell.selected)

        appSettingsMock.backgroundTheme = "celadon"
        verify(celadonCell.selected)
        verify(!warmCell.selected)
    }

    function test_missingSettingsRefRendersAndClickIsNoop() {
        dialog.appSettingsRef = null
        dialog.open()
        wait(20)
        compare(findChild(dialog, "settingsThemeRepeater").count, 6)
        var thumb = findChild(dialog, "settingsThemeThumb-sunset")
        mouseClick(thumb) // 缺 appSettings（测试/降级）时：不崩溃、不写入。
        compare(appSettingsMock.backgroundTheme, "warmPaper")
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`
Expected: FAIL（SettingsDialog 不存在）。

- [x] **Step 3: 实现组件**

新建 `qml/components/SettingsDialog.qml`：

```qml
// 画廊 delegate 引用外层 root，按项目惯例显式绑定组件作用域（EditTaskDialog 先例）。
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."

// 设置弹窗：本期只有"背景主题"一栏；框架通用，将来其它设置逐步收进来。
// 主题即点即切即持久化（写 appSettingsRef.backgroundTheme），不设确认按钮。
Popup {
    id: root

    property var appSettingsRef: null

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(420, parent ? Math.max(320, parent.width - 64) : 420)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function selectTheme(themeId) {
        // 缺 appSettings（测试/降级）时画廊只展示不写入，与全应用守卫模式一致。
        if (root.appSettingsRef) {
            root.appSettingsRef.backgroundTheme = themeId;
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.94
                to: 1.0
                duration: 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: 220
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1.0
                to: 0.94
                duration: 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: 220
                easing.type: Easing.InQuad
            }
        }
    }

    Overlay.modal: Rectangle {
        color: "#66000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: 180
                easing.type: Easing.InOutQuad
            }
        }
    }

    background: Rectangle {
        id: panel
        objectName: "settingsDialogPanel"

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space12

        Text {
            Layout.leftMargin: Theme.space16
            Layout.topMargin: Theme.space16
            text: "设置"
            textFormat: Text.PlainText
            color: Theme.ink
            font.pixelSize: Theme.fontLg
            font.weight: Font.Bold
        }

        Text {
            Layout.leftMargin: Theme.space16
            text: "背景主题"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            font.weight: Font.Bold
        }

        GridLayout {
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            columns: 3
            rowSpacing: Theme.space12
            columnSpacing: Theme.space12

            Repeater {
                id: themeRepeater
                objectName: "settingsThemeRepeater"

                model: Theme.backgroundThemes

                delegate: Column {
                    id: themeCell

                    required property var modelData

                    objectName: "settingsThemeCell-" + themeCell.modelData.id
                    // 选中态直接绑设置属性（函数调用不具备响应性，这里必须是属性链）。
                    readonly property bool selected: root.appSettingsRef
                        ? root.appSettingsRef.backgroundTheme === themeCell.modelData.id
                        : themeCell.modelData.id === "warmPaper"

                    spacing: Theme.space4

                    Rectangle {
                        id: thumbFrame
                        objectName: "settingsThemeThumb-" + themeCell.modelData.id

                        width: 104
                        height: 66
                        radius: Theme.radiusMd
                        clip: true
                        color: themeCell.selected ? Theme.accentSoft : "transparent"
                        border.color: themeCell.selected ? Theme.accent : Theme.border
                        border.width: themeCell.selected ? 2 : 1

                        BackgroundWallpaper {
                            // 缩略图与壁纸层同组件同定义：画廊所见即所得。
                            anchors.fill: parent
                            anchors.margins: 3
                            themeId: themeCell.modelData.id
                        }

                        Rectangle {
                            // 迷你磨砂条：让用户换主题前预感玻璃面板的观感。
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            anchors.bottomMargin: 8
                            height: 16
                            radius: Theme.radiusSm
                            color: Theme.glassCard
                            border.color: Theme.glassBorder
                            border.width: 1
                        }

                        Rectangle {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 4
                            width: 16
                            height: 16
                            radius: 8
                            color: Theme.accent
                            visible: themeCell.selected

                            Text {
                                anchors.centerIn: parent
                                text: "✓"
                                textFormat: Text.PlainText
                                color: Theme.surface
                                font.pixelSize: 10
                                font.weight: Font.Bold
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectTheme(themeCell.modelData.id)
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: themeCell.modelData.name
                        textFormat: Text.PlainText
                        color: themeCell.selected ? Theme.ink : Theme.inkSoft
                        font.pixelSize: Theme.fontSm
                    }
                }
            }
        }

        Button {
            id: closeButton

            Layout.alignment: Qt.AlignRight
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            text: "关闭"
            implicitWidth: 80
            implicitHeight: 36

            onClicked: root.close()

            background: Rectangle {
                color: closeButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: closeButton.text
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
```

- [x] **Step 4: qrc 注册**

在 `resources/qml.qrc` 的 BackgroundWallpaper 行之后加：

```xml
        <file alias="qml/components/SettingsDialog.qml">../qml/components/SettingsDialog.qml</file>
```

- [x] **Step 5: 跑测试确认通过（2 次）+ lint**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`（×2）
Expected: 全绿 ×2。若 `mouseClick(thumb)` 因 Popup overlay 坐标映射失败（点击无效果而非崩溃），改为 `mouseClick(thumb, thumb.width / 2, thumb.height / 2)` 再试；仍不行则在测试注释说明后改调 `dialog.selectTheme(...)` 并额外断言 MouseArea 存在（`verify(findChild(thumb, ...))` 不可用时用 thumbFrame.children 遍历找 MouseArea）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/SettingsDialog.qml`
Expected: 零警告。

- [x] **Step 6: MainWindow 接线**

`qml/MainWindow.qml`：Sidebar 实例（约 167-182 行）内、`onDataExportRequested: exportDialog.open()` 之后加：

```qml
            onSettingsRequested: settingsDialog.open()
```

`ExportDialog` 实例之后加：

```qml
    SettingsDialog {
        id: settingsDialog

        parent: root
        appSettingsRef: root.appSettingsRef
    }
```

- [x] **Step 7: 主窗口回归（2 次）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`（×2）
Expected: 全绿 ×2（接线不破坏既有测试）。

- [x] **Step 8: 提交**

```bash
git add qml/components/SettingsDialog.qml resources/qml.qrc qml/MainWindow.qml tests/qml/tst_settings_dialog.qml
git commit -m "新增设置弹窗与背景主题画廊并接线侧栏入口"
```

---

### Task 7: 全量回归

**Files:** 无新改动（验证任务）。

- [x] **Step 1: 全量构建 + 三套测试**

Run: `cmake --build build && ctest --test-dir build --output-on-failure`
Expected: PomodoroTodoTests、CountdownServiceTests、PomodoroTodoQmlTests 3/3 通过。QML 套件若在 tst_ui_optimization.qml 出现已知的窗口曝光类偶发失败，重跑一次区分环境噪声（该文件有既有偶发基线）；本计划新增/改动的测试文件必须稳定绿。

- [x] **Step 2: 冒烟指引（报告给用户）**

构建部署后人工确认：侧栏透出壁纸；侧栏底部「设置」条目 → 弹窗画廊 6 张缩略图；点缩略图侧栏区域背景即时变化；重启 app 主题保留。主内容区仍为暖纸底属预期（计划二处理）。
