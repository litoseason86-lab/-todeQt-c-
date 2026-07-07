# 专注计时环重设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把专注计时页番茄环从扁平单色描边重塑为「暖霞双色玻璃表盘」，并让计时数字更秀气、支持在设置里切换纤细/中黑两种字体。

**Architecture:** 纯视觉/材质升级，不动状态机与布局。`FocusRing`（Canvas）重写 `onPaint` 画出磨砂玻璃盘 + 顶部高光 + 双色发光弧；所有颜色走新增 Theme 令牌。计时数字改用可切换字重（Light/Medium），冒号经 `Text.StyledText` 弱化颜色；切换由新增 `AppSettings.slimClockFont` 驱动，设置弹窗复用现有 `PreferenceSwitchRow`。

**Tech Stack:** Qt 6.9 / QML (Qt Quick, Canvas)、C++（AppSettings/QSettings）、Qt Test + qmltestrunner。

## Global Constraints

- 所有颜色必须走 `Theme.*` 令牌，禁止在 QML 里硬编码色值。
- 计时数字主色维持 `accentInk` 级别对比（AA 达标）；本次只降字重、不降对比。
- `reduceMotion` 行为不受影响：本次不新增任何动画，辉光/高光为静态绘制。
- 保留所有既有 `objectName`；既有测试必须继续通过。
- 不断言 `item.visible === true`（本项目 QML 测试沙箱下不可靠、会级联失败）。
- `slimClockFont` 默认 `true`（纤细 Light）。
- 配置/构建/测试命令（Qt 6.9.0）：
  - 配置：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`
  - 构建：`cmake --build build`
  - 全部测试：`ctest --test-dir build --output-on-failure`
  - 单个 C++ 测试：`ctest --test-dir build -R FontAssetsTests --output-on-failure`
  - 单个 QML 文件快速迭代：`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`

---

## File Structure

- `resources/fonts/SpaceGrotesk-Light.ttf` — 新增字体资源（Light 300 静态实例，family 名须为 "Space Grotesk"）。
- `resources/fonts.qrc` — 注册 Light 别名。
- `src/main.cpp` — 启动时注册 Light ttf。
- `tests/FontAssetsTests.cpp` — 新增 Light 字重守门用例。
- `qml/Theme.qml` — 新增 9 个专注环令牌。
- `tests/qml/tst_theme_tokens.qml` — 新令牌断言。
- `src/services/AppSettings.h` / `.cpp` — 新增 `slimClockFont` 属性。
- `tests/ServiceTests.cpp` — `slimClockFont` 往返测试。
- `qml/components/SettingsDialog.qml` — 新增「纤细计时字体」开关行。
- `tests/qml/tst_settings_dialog.qml` — 开关行测试 + mock 加属性。
- `qml/views/FocusView.qml` — `ringTimeMarkup()` helper、`focusRingTimeText` 改 StyledText、两个计时数字改字重绑定、`FocusRing.onPaint` 玻璃重写。
- `tests/qml/tst_focus_view.qml` — markup helper 与字重绑定测试 + mock 加属性。

---

## Task 1: 打包 Space Grotesk Light + 字重自动守门

**Files:**
- Create: `resources/fonts/SpaceGrotesk-Light.ttf`
- Modify: `resources/fonts.qrc`
- Modify: `src/main.cpp:31-35`
- Test: `tests/FontAssetsTests.cpp`

**Interfaces:**
- Produces: 资源别名 `:/fonts/SpaceGrotesk-Light.ttf`，注册后 family 名为 `"Space Grotesk"`、样式含 `"Light"`，供 Task 5 的 `Font.Light` 解析到真实 Light 字模。

- [ ] **Step 1: 放入字体文件**

从 Google Fonts（Space Grotesk，OFL 许可）获取 **Light (300) 静态实例**，保存为 `resources/fonts/SpaceGrotesk-Light.ttf`。要求其 family 名为 `Space Grotesk`（与现有 Medium/Bold 一致）。放好后自检：

Run: `ls -l resources/fonts/SpaceGrotesk-Light.ttf`
Expected: 文件存在、大小非零（数十 KB 量级）。

- [ ] **Step 2: 注册到 qrc**

编辑 `resources/fonts.qrc`，在 `<qresource prefix="/">` 内新增一行（放在 Medium 行之后）：

```xml
        <file alias="fonts/SpaceGrotesk-Light.ttf">fonts/SpaceGrotesk-Light.ttf</file>
```

- [ ] **Step 3: 启动时注册字体**

编辑 `src/main.cpp`，在 `bundledFonts` 列表里加入 Light（放在 Medium 之后）：

```cpp
    const QStringList bundledFonts = {
        QStringLiteral(":/fonts/SpaceGrotesk-Light.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Bold.ttf"),
        QStringLiteral(":/fonts/BricolageGrotesque-Bold.ttf"),
    };
```

- [ ] **Step 4: 写失败测试（字重守门）**

编辑 `tests/FontAssetsTests.cpp`。在 `private slots:` 里声明新用例（放在 `spaceGroteskMediumRegistersAsSpaceGrotesk();` 之前或之后均可）：

```cpp
    void spaceGroteskLightRegistersAsSpaceGroteskLight();
```

在文件中 `bricolageBoldRegistersAsBricolage()` 定义之后，新增实现。主证据用 id 作用域的 family + `QFontInfo` 字重，`styles()` 仅作辅助（避免开发机装了系统版 Space Grotesk Light 造成全局假绿）：

```cpp
void FontAssetsTests::spaceGroteskLightRegistersAsSpaceGroteskLight()
{
    const QString resourcePath = QStringLiteral(":/fonts/SpaceGrotesk-Light.ttf");
    QVERIFY2(QFile(resourcePath).exists(),
             qPrintable(QStringLiteral("资源不存在: ") + resourcePath));

    const int id = QFontDatabase::addApplicationFont(resourcePath);
    QVERIFY2(id != -1,
             qPrintable(QStringLiteral("注册失败: ") + resourcePath));

    // 主证据 1：资源自身的 family 名（id 作用域，避免全局假绿）。
    const QStringList families = QFontDatabase::applicationFontFamilies(id);
    QVERIFY2(families.contains(QStringLiteral("Space Grotesk")),
             qPrintable(QStringLiteral("family 名不符，实际 ") + families.join(QLatin1Char(','))));

    // 主证据 2：请求 Light 字重时，解析到的字体确实是 Light 档，
    // 拦住「family 叫 Space Grotesk 但其实是 Regular/Medium」的塞错文件。
    QFont requested(QStringLiteral("Space Grotesk"));
    requested.setWeight(QFont::Light);
    const int resolvedWeight = QFontInfo(requested).weight();
    QVERIFY2(resolvedWeight <= QFont::Normal,
             qPrintable(QStringLiteral("请求 Light 未解析到细字重，实际 weight=")
                        + QString::number(resolvedWeight)));

    // 辅助证据（不作唯一依据）：全局家族样式里应出现 Light。
    const QStringList styles = QFontDatabase::styles(QStringLiteral("Space Grotesk"));
    QVERIFY2(styles.contains(QStringLiteral("Light")),
             qPrintable(QStringLiteral("styles 无 Light（仅辅助），实际 ") + styles.join(QLatin1Char(','))));
}
```

确保文件顶部已 `#include <QFontInfo>`（若无则加上；`<QFontDatabase>`、`<QFile>` 已有）。

- [ ] **Step 5: 构建并确认测试通过**

Run:
```bash
cmake --build build && ctest --test-dir build -R FontAssetsTests --output-on-failure
```
Expected: `FontAssetsTests` PASS，包含新用例 `spaceGroteskLightRegistersAsSpaceGroteskLight`。

> 若 Step 5 失败且报 `QFontInfo` 未解析到 Light：说明放入的 ttf 不是真 Light 300（守门生效）。换正确的 Light 静态实例后重试。

- [ ] **Step 6: 提交**

```bash
git add resources/fonts/SpaceGrotesk-Light.ttf resources/fonts.qrc src/main.cpp tests/FontAssetsTests.cpp
git commit -m "feat(fonts): 打包 Space Grotesk Light 并新增字重守门测试"
```

---

## Task 2: 新增专注环 Theme 令牌

**Files:**
- Modify: `qml/Theme.qml`（「专注页休息态强调色」区附近）
- Test: `tests/qml/tst_theme_tokens.qml`

**Interfaces:**
- Produces: `Theme.focusRingArcStart/Mid/End`、`focusRingTrack`、`focusGlassCenter/Edge/Shadow/Highlight`、`focusColonMuted`（均为 `color`），供 Task 5、Task 6 使用。

- [ ] **Step 1: 写失败测试**

编辑 `tests/qml/tst_theme_tokens.qml`，在 `test_glassTokens()` 之后新增：

```qml
    function test_focusRingTokens() {
        verify(Qt.colorEqual(Theme.focusRingArcStart, "#f1bd7e"), "focusRingArcStart 取值不对")
        verify(Qt.colorEqual(Theme.focusRingArcMid, "#f4d3ab"), "focusRingArcMid 取值不对")
        verify(Qt.colorEqual(Theme.focusRingArcEnd, "#f4c3bd"), "focusRingArcEnd 取值不对")
        verify(Qt.colorEqual(Theme.focusRingTrack, "#faf1e8"), "focusRingTrack 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassCenter, "#fffefb"), "focusGlassCenter 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassEdge, "#fdf3ee"), "focusGlassEdge 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassShadow, "#e2b9a6"), "focusGlassShadow 取值不对")
        verify(Qt.colorEqual(Theme.focusGlassHighlight, "#ffffff"), "focusGlassHighlight 取值不对")
        verify(Qt.colorEqual(Theme.focusColonMuted, "#e8bda6"), "focusColonMuted 取值不对")
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`
Expected: FAIL（`Theme.focusRingArcStart` 为 undefined，颜色比较不通过）。

- [ ] **Step 3: 新增令牌**

编辑 `qml/Theme.qml`，在 `focusBreakAccent` 定义（`readonly property color focusBreakAccent: chartColors[3]`）之后新增：

```qml
    // —— 专注计时环（玻璃表盘）——
    // 进度弧双色霞光渐变（仅专注进行态用；休息/完成态退化为单色）。
    readonly property color focusRingArcStart: "#f1bd7e"   // 琥珀
    readonly property color focusRingArcMid: "#f4d3ab"     // 柔金
    readonly property color focusRingArcEnd: "#f4c3bd"     // 樱粉
    readonly property color focusRingTrack: "#faf1e8"      // 底色轨道
    // 玻璃内盘径向渐变与顶部高光；shadow 绘制时另配低 alpha。
    readonly property color focusGlassCenter: "#fffefb"
    readonly property color focusGlassEdge: "#fdf3ee"
    readonly property color focusGlassShadow: "#e2b9a6"
    readonly property color focusGlassHighlight: "#ffffff"
    // 计时冒号弱化色：只降颜色不降字重（Space Grotesk 仅打包 300/500/700）。
    readonly property color focusColonMuted: "#e8bda6"
```

- [ ] **Step 4: 运行确认通过**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add qml/Theme.qml tests/qml/tst_theme_tokens.qml
git commit -m "feat(theme): 新增专注计时环玻璃/双色弧/冒号令牌"
```

---

## Task 3: AppSettings 新增 slimClockFont

**Files:**
- Modify: `src/services/AppSettings.h`
- Modify: `src/services/AppSettings.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces: `AppSettings::slimClockFont() -> bool`（默认 `true`）、`setSlimClockFont(bool)`、信号 `slimClockFontChanged()`，QML 侧属性名 `slimClockFont`。供 Task 4、Task 5 消费。

- [ ] **Step 1: 写失败测试**

编辑 `tests/ServiceTests.cpp`。在 `private slots:` 中 `appSettingsReduceMotionRoundTrip();` 之后声明：

```cpp
    void appSettingsSlimClockFontRoundTrip();
```

在 `appSettingsReduceMotionRoundTrip()` 实现之后新增（默认值为 `true`，与 reduceMotion 相反）：

```cpp
void ServiceTests::appSettingsSlimClockFontRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.slimClockFont(), true); // 默认纤细

        QSignalSpy spy(&settings, &AppSettings::slimClockFontChanged);
        settings.setSlimClockFont(false);
        QCOMPARE(settings.slimClockFont(), false);
        QCOMPARE(spy.count(), 1);

        settings.setSlimClockFont(false); // 同值不再发信号
        QCOMPARE(spy.count(), 1);
    }

    AppSettings reloaded(path);
    QCOMPARE(reloaded.slimClockFont(), false); // 已落盘
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cmake --build build`
Expected: 编译失败（`slimClockFont` / `setSlimClockFont` / `slimClockFontChanged` 未声明）。

- [ ] **Step 3: 声明属性（.h）**

编辑 `src/services/AppSettings.h`：
在 `Q_PROPERTY(bool reduceMotion ...)` 之后加：

```cpp
    Q_PROPERTY(bool slimClockFont READ slimClockFont WRITE setSlimClockFont NOTIFY slimClockFontChanged)
```

在 `void setReduceMotion(bool enabled);` 之后加：

```cpp
    bool slimClockFont() const;
    void setSlimClockFont(bool enabled);
```

在 `void reduceMotionChanged();` 之后加：

```cpp
    void slimClockFontChanged();
```

- [ ] **Step 4: 实现（.cpp）**

编辑 `src/services/AppSettings.cpp`：
在文件顶部 key 常量区（`kReduceMotionKey` 附近）加：

```cpp
const auto kSlimClockFontKey = QStringLiteral("appearance/slimClockFont");
```

在 `setReduceMotion` 实现之后新增（默认 `true`，change-guard 与既有一致）：

```cpp
bool AppSettings::slimClockFont() const
{
    return m_settings->value(kSlimClockFontKey, true).toBool();
}

void AppSettings::setSlimClockFont(bool enabled)
{
    if (slimClockFont() == enabled) {
        return;
    }
    m_settings->setValue(kSlimClockFontKey, enabled);
    emit slimClockFontChanged();
}
```

- [ ] **Step 5: 构建并确认测试通过**

Run:
```bash
cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure
```
Expected: PASS，含 `appSettingsSlimClockFontRoundTrip`。

- [ ] **Step 6: 提交**

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp tests/ServiceTests.cpp
git commit -m "feat(settings): 新增 slimClockFont 偏好（默认纤细）"
```

---

## Task 4: SettingsDialog 新增「纤细计时字体」开关

**Files:**
- Modify: `qml/components/SettingsDialog.qml:291-301`（减少动效行之后）
- Test: `tests/qml/tst_settings_dialog.qml`

**Interfaces:**
- Consumes: `AppSettings.slimClockFont`（Task 3）、既有 `PreferenceSwitchRow` 组件。
- Produces: objectName `settingsSlimClockFontSwitchRow` / `settingsSlimClockFontSwitchCaption` / `settingsSlimClockFontSwitch` / `settingsSlimClockFontSwitchTrack` / `settingsSlimClockFontSwitchThumb`、分隔线 `settingsPreferenceDividerSlimClock`。

- [ ] **Step 1: mock 加属性 + 写失败测试**

编辑 `tests/qml/tst_settings_dialog.qml`。给 `appSettingsMock` 加属性（在 `property bool reduceMotion: false` 之后）：

```qml
        property bool slimClockFont: true
```

在 `init()` 里补一行重置（在 `appSettingsMock.reduceMotion = false` 之后）：

```qml
        appSettingsMock.slimClockFont = true
```

在 `test_clickingPreferenceSwitchTogglesOnce()` 之后新增三个测试：

```qml
    function test_slimClockFontSwitchBindsSetting() {
        appSettingsMock.slimClockFont = true
        dialog.open()
        wait(20)

        var sw = findChild(dialog, "settingsSlimClockFontSwitch")
        verify(sw)
        compare(sw.checked, true)

        sw.toggle()
        sw.toggled()
        compare(appSettingsMock.slimClockFont, false)
    }

    function test_slimClockFontRowTogglesOnce() {
        appSettingsMock.slimClockFont = true
        dialog.open()
        wait(20)

        var row = findChild(dialog, "settingsSlimClockFontSwitchRow")
        verify(row)
        mouseClick(row, 8, row.height / 2, Qt.LeftButton, Qt.NoModifier)
        compare(appSettingsMock.slimClockFont, false)
    }

    function test_slimClockFontSwitchTogglesOnce() {
        appSettingsMock.slimClockFont = true
        dialog.open()
        wait(20)

        var sw = findChild(dialog, "settingsSlimClockFontSwitch")
        verify(sw)
        mouseClick(sw)
        compare(appSettingsMock.slimClockFont, false)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`
Expected: FAIL（`findChild` 找不到 `settingsSlimClockFontSwitch`，返回 null）。

- [ ] **Step 3: 新增开关行**

编辑 `qml/components/SettingsDialog.qml`，在减少动效 `PreferenceSwitchRow { ... switchName: "settingsReduceMotionSwitch" ... }` 之后、`settingsPreferenceGroup` 的闭合 `}` 之前，插入：

```qml
                RowDivider {
                    objectName: "settingsPreferenceDividerSlimClock"
                }

                PreferenceSwitchRow {
                    label: "纤细计时字体"
                    caption: "更秀气的表盘数字；关闭则用更清晰的中黑"
                    switchName: "settingsSlimClockFontSwitch"
                    checkedValue: root.appSettingsRef ? root.appSettingsRef.slimClockFont : true
                    onToggledTo: function (value) {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.slimClockFont = value
                        }
                    }
                }
```

- [ ] **Step 4: 运行确认通过**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`
Expected: PASS（含 3 个新测试，且既有偏好测试仍绿）。

- [ ] **Step 5: 提交**

```bash
git add qml/components/SettingsDialog.qml tests/qml/tst_settings_dialog.qml
git commit -m "feat(settings-ui): 偏好组新增纤细计时字体开关"
```

---

## Task 5: FocusView 计时数字精修（字重切换 + 冒号弱化）

**Files:**
- Modify: `qml/views/FocusView.qml`（新增 `ringTimeMarkup()`；改 `focusRingTimeText` 与 `focusFreeTimeText`）
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: `Theme.focusColonMuted`（Task 2）、`root.settings.slimClockFont`（Task 3）、已打包 Light 字重（Task 1）。
- Produces: helper `ringTimeMarkup(text) -> string`；两个计时数字的 `font.weight` 随 `slimClockFont` 在 `Font.Light`/`Font.Medium` 间切换。

- [ ] **Step 1: mock 加属性 + 写失败测试**

编辑 `tests/qml/tst_focus_view.qml`。给 `appSettingsMock` 加属性（在 `property bool reduceMotion: false` 之后）：

```qml
        property bool slimClockFont: true
```

在文件末尾最后一个 `}` 之前，新增测试。`ringTimeMarkup` 校验只接受 `[0-9:]+` 且恰好一个冒号，否则回落原串：

```qml
    function test_ringTimeMarkupWrapsColonOnly() {
        var out = view.ringTimeMarkup("25:00")
        verify(out.indexOf("<font") !== -1, "标准 MM:SS 应包裹冒号 font 标签")
        verify(out.indexOf("25") === 0, "分钟段应在标签前原样保留")
        verify(out.indexOf("00") !== -1, "秒段应保留")
    }

    function test_ringTimeMarkupFallsBackOnNonStandard() {
        // 非 [0-9:]+ 或非单冒号：回落纯文本，杜绝标签注入/异常。
        compare(view.ringTimeMarkup("<b>x</b>"), "<b>x</b>")
        compare(view.ringTimeMarkup("01:02:03"), "01:02:03")
        compare(view.ringTimeMarkup("2500"), "2500")
    }

    function test_clockDigitsFollowSlimSetting() {
        var ringText = findChild(view, "focusRingTimeText")
        var freeText = findChild(view, "focusFreeTimeText")
        verify(ringText)
        verify(freeText)

        appSettingsMock.slimClockFont = true
        compare(ringText.font.weight, Font.Light)
        compare(freeText.font.weight, Font.Light)

        appSettingsMock.slimClockFont = false
        compare(ringText.font.weight, Font.Medium)
        compare(freeText.font.weight, Font.Medium)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
Expected: FAIL（`ringTimeMarkup` 不是函数；`font.weight` 仍是 bold 派生值）。

- [ ] **Step 3: 新增 ringTimeMarkup helper**

编辑 `qml/views/FocusView.qml`，在 `primaryTimeColor()` 函数之后新增：

```qml
    function ringTimeMarkup(plain) {
        // 冒号弱化只改颜色不改字重：把恰好单冒号的 MM:SS 在冒号处包一层 font 色。
        // 入参校验 + 回落，避免未来文案变化把 StyledText 搞出标签注入或显示异常。
        var text = String(plain)
        if (!/^[0-9:]+$/.test(text)) {
            return text
        }
        var parts = text.split(":")
        if (parts.length !== 2) {
            return text
        }
        return parts[0] + '<font color="' + Theme.focusColonMuted + '">:</font>' + parts[1]
    }
```

- [ ] **Step 4: 改 focusRingTimeText（StyledText + 字重绑定）**

编辑 `qml/views/FocusView.qml` 的 `focusRingTimeText`（约 671 行）：把 `text`、`textFormat`、去掉 `font.bold`、加 `font.weight`：

```qml
                    Text {
                        objectName: "focusRingTimeText"
                        Layout.alignment: Qt.AlignHCenter
                        text: root.ringTimeMarkup(root.primaryTimeText())
                        textFormat: Text.StyledText
                        font.pixelSize: root.state === "pomoIdle"
                                        ? (root.panelExpanded ? 42 : 56)
                                        : Theme.fontDisplay
                        font.family: Theme.fontFamilyClock
                        font.weight: (root.settings && root.settings.slimClockFont) ? Font.Light : Font.Medium
                        color: root.primaryTimeColor()
                        horizontalAlignment: Text.AlignHCenter
                    }
```

- [ ] **Step 5: 改 focusFreeTimeText（仅字重，一行）**

编辑 `focusFreeTimeText`（约 635 行）：把 `font.bold: true` 替换为字重绑定，其余（`textFormat`/颜色/objectName/布局）不动：

```qml
                font.family: Theme.fontFamilyClock
                font.weight: (root.settings && root.settings.slimClockFont) ? Font.Light : Font.Medium
                color: Theme.accentInk
```

（即：删除原 `font.bold: true` 行，插入上面的 `font.weight` 行；`font.family`、`color` 保持原样，此处仅为定位上下文。）

- [ ] **Step 6: 运行确认通过**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
Expected: PASS（含 3 个新测试；`test_timeNumeralsUseClockFamily`、`test_freeTimeNumeralUsesReadableInk` 仍绿）。

- [ ] **Step 7: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "feat(focus): 计时数字支持纤细/中黑切换并弱化冒号"
```

---

## Task 6: FocusRing 玻璃表盘绘制重写

**Files:**
- Modify: `qml/views/FocusView.qml`（`FocusRing` 组件的 `onPaint`，约 438-488 行；`strokeWidth` 常量约 423 行）
- Test: `tests/qml/tst_focus_view.qml`（回归 + 轻断言）

**Interfaces:**
- Consumes: `Theme.focusRingArcStart/Mid/End`、`focusRingTrack`、`focusGlassCenter/Edge/Shadow/Highlight`（Task 2）；组件既有属性 `progress`/`ringColor`/`showPreview`/`dimmed`/`strokeWidth`。
- Produces: 无新公开接口；`objectName: "focusRing"` 保持。

> 说明：Canvas 逐像素不做单元断言（本项目无此设施）。本任务以「既有 tst_focus_view 全绿（契约/objectName 未破）」+「构建后人工/截图视觉确认」为验收；下附一条轻量断言守住 objectName 存续。

- [ ] **Step 1: 写/确认轻量回归断言**

编辑 `tests/qml/tst_focus_view.qml`，在文件末尾最后一个 `}` 之前新增：

```qml
    function test_focusRingObjectNamePreserved() {
        var ring = findChild(view, "focusRing")
        verify(ring)
        // 契约属性仍在（Canvas 属性驱动，重写 onPaint 不得破坏这些绑定入口）。
        verify(ring.strokeWidth !== undefined)
        verify(ring.progress !== undefined)
    }
```

- [ ] **Step 2: 运行（此断言当前应已通过，作为重写前基线）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
Expected: PASS（基线：重写前后都必须绿）。

- [ ] **Step 3: 微调 strokeWidth 常量**

编辑 `FocusRing` 的 `readonly property real strokeWidth: 16` 改为 `14`（贴合 L2 较细弧；保持 readonly 内部常量）：

```qml
        readonly property real strokeWidth: 14
```

- [ ] **Step 4: 重写 onPaint**

把 `FocusRing` 的整个 `onPaint` 替换为下面版本。绘制顺序：玻璃盘（带落影，用完清阴影）→ 顶部高光 → 待机分支 → 底轨 → 弧辉光底 → 实弧。休息/完成态用单色（`ring.ringColor`），专注态用双色渐变：

```qml
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            var centerX = width / 2
            var centerY = height / 2
            var radius = Math.max(0, Math.min(width, height) / 2 - ring.strokeWidth / 2 - 2)
            var discR = Math.max(0, radius - ring.strokeWidth / 2 - 6)
            ctx.lineCap = "round"

            // 1) 磨砂玻璃内盘 + 柔和落影（阴影是全局态，画完立刻清零）。
            ctx.save()
            ctx.shadowColor = Qt.rgba(0.886, 0.725, 0.651, 0.15) // focusGlassShadow @ ~.15
            ctx.shadowBlur = 14
            ctx.shadowOffsetY = 7
            var disc = ctx.createRadialGradient(centerX, centerY - discR * 0.16, discR * 0.1,
                                                centerX, centerY, discR)
            disc.addColorStop(0, Theme.focusGlassCenter)
            disc.addColorStop(1, Theme.focusGlassEdge)
            ctx.beginPath()
            ctx.fillStyle = disc
            ctx.arc(centerX, centerY, discR, 0, Math.PI * 2, false)
            ctx.fill()
            ctx.restore() // 清除 shadow，避免污染后续描边/高光

            // 2) 顶部高光：一条极淡的白色椭圆渐变，做出受光玻璃。
            ctx.save()
            ctx.beginPath()
            ctx.ellipse(centerX - discR * 0.55, centerY - discR * 0.7, discR * 1.1, discR * 0.7)
            var hl = ctx.createLinearGradient(0, centerY - discR * 0.7, 0, centerY)
            hl.addColorStop(0, Qt.rgba(1, 1, 1, 0.85))
            hl.addColorStop(1, Qt.rgba(1, 1, 1, 0))
            ctx.fillStyle = hl
            ctx.fill()
            ctx.restore()

            // 3) 待机预览：只画极淡完整轨道 + 顶部 15° 强调弧，不画进度弧。
            if (ring.showPreview) {
                ctx.beginPath()
                ctx.lineWidth = ring.strokeWidth
                ctx.strokeStyle = Theme.borderSubtle
                ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
                ctx.stroke()

                ctx.beginPath()
                ctx.globalAlpha = 0.45
                ctx.strokeStyle = Theme.accent
                ctx.arc(centerX, centerY, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI / 12, false)
                ctx.stroke()
                ctx.globalAlpha = 1
                return
            }

            // 4) 底色轨道。
            ctx.beginPath()
            ctx.lineWidth = ring.strokeWidth
            ctx.strokeStyle = Theme.focusRingTrack
            ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
            ctx.stroke()

            var clamped = Math.max(0, Math.min(1, ring.progress))
            if (clamped <= 0) {
                return
            }
            var start = -Math.PI / 2
            var end = start + clamped * Math.PI * 2

            // 进度弧描边样式：专注态双色霞光渐变；休息/完成态单色（ring.ringColor）。
            var arcStroke
            if (Qt.colorEqual(ring.ringColor, Theme.accent)) {
                var grad = ctx.createLinearGradient(centerX, centerY - radius,
                                                    centerX + radius, centerY + radius)
                grad.addColorStop(0, Theme.focusRingArcStart)
                grad.addColorStop(0.5, Theme.focusRingArcMid)
                grad.addColorStop(1, Theme.focusRingArcEnd)
                arcStroke = grad
            } else {
                arcStroke = ring.ringColor
            }

            // 5) 辉光底：加宽、低透明的同色底层（不使用 Canvas 阴影，规避全局态污染）。
            ctx.save()
            ctx.globalAlpha = 0.35
            ctx.beginPath()
            ctx.lineWidth = ring.strokeWidth + 6
            ctx.strokeStyle = arcStroke
            ctx.arc(centerX, centerY, radius, start, end, false)
            ctx.stroke()
            ctx.restore()

            // 6) 实弧。
            ctx.beginPath()
            ctx.lineWidth = ring.strokeWidth
            ctx.strokeStyle = arcStroke
            ctx.arc(centerX, centerY, radius, start, end, false)
            ctx.stroke()
        }
```

> 备注：`ctx.ellipse` 在 Qt Canvas 可用；若目标 Qt 版本不支持，退化为 `ctx.arc(centerX, centerY - discR*0.35, discR*0.8, Math.PI, 0)` 配同一线性渐变填充。本项目 Qt 6.9 支持 `ellipse`。

- [ ] **Step 5: 运行 QML 回归**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
Expected: PASS（含新 `test_focusRingObjectNamePreserved`；其余全绿）。

- [ ] **Step 6: 全量测试**

Run: `cmake --build build && ctest --test-dir build --output-on-failure`
Expected: 全部 PASS。

- [ ] **Step 7: 视觉确认（人工）**

构建并运行应用，进入专注计时页番茄模式，逐一目视：
- 待机态：玻璃盘 + 顶部高光 + 极淡轨道 + 顶部小段强调弧；
- 专注中：琥珀→柔金→樱粉双色发光弧 + 玻璃盘；数字纤细、冒号偏淡；
- 暂停：整体变淡；休息：弧转苔绿单色；完成：满环转绿。
用 `/run` 或截图工具留一张专注中截图确认与 L2 定稿一致。

- [ ] **Step 8: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "feat(focus): 计时环重绘为暖霞双色玻璃表盘"
```

---

## Self-Review 结论

- **Spec coverage**：玻璃环(Task 6)、9 令牌(Task 2)、双字体+冒号(Task 5)、Light 打包+字重守门(Task 1)、slimClockFont(Task 3)、设置开关+objectName 契约(Task 4)、两处评审补点（markup 入参校验/回落见 Task 5 helper；Light 主证据用 id 作用域见 Task 1 测试）——全部有对应任务。
- **作用域钉死**：`slimClockFont` 同管 ring/free 两处字重（Task 5 Step 4、5）；玻璃/双色弧/冒号仅 ring。
- **Type consistency**：`slimClockFont`/`setSlimClockFont`/`slimClockFontChanged`、`ringTimeMarkup`、令牌名在各任务间一致。
- **无占位符**：所有步骤含真实代码与可执行命令。
