# 排版身份（数字英雄字体系统）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给数字一套排版身份——计时数字用 Space Grotesk（冷·精确表盘），统计/倒计时数字用 Bricolage Grotesque（暖·累积成果），中文全部维持苹方。

**Architecture:** 三个 OFL 静态 ttf 经 `fonts.qrc` 打包、main.cpp 用 `QFontDatabase::addApplicationFont` 注册；Theme 出两个字族令牌；仅在几处数字 Text 加 `font.family` + objectName。字体资源正确性由独立 GUI 测试目标 `FontAssetsTests`（offscreen、id 作用域校验 family）硬守门；令牌应用由 QML 测试断言驱动属性。

**Tech Stack:** Qt 6.9 / C++17 / QML / QFontDatabase / Qt Test + qmltestrunner

**Depends on:** 背景一/二阶段已在 main；本计划在 `type-identity` 分支。

## Global Constraints

- 注释、提交说明一律中文；注释解释"为什么/边界"（AGENTS.md）。
- **自动流程一律无头，禁含 `open`**（AGENTS.md）：C++ 测试 `QT_QPA_PLATFORM=offscreen ./build/<Target>`；QML `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`；ctest 同加 offscreen。验收 = 连续 2 次全绿。`cmake --build build` 会自动部署到 /Applications；`open /Applications/番茄Todo.app` **只在人工视觉验收时手动执行**，不进任何自动步骤。
- 构建前缀：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`（已配置则直接 `cmake --build build`）。**不得改 build/**。
- 字族令牌定稿：`fontFamilyClock = "Space Grotesk"`、`fontFamilyData = "Bricolage Grotesque"`。
- 位点字重一处不改：Space Grotesk 500（侧栏）/700（专注页），Bricolage 700（统计+倒计时）——恰好对应打包的三个 ttf。

---

### Task 1: 字体资产 + fonts.qrc + CMake 接线 + FontAssetsTests 守门

**Files:**

- 新增: `resources/fonts/SpaceGrotesk-Medium.ttf`、`SpaceGrotesk-Bold.ttf`、`BricolageGrotesque-Bold.ttf`、`OFL-SpaceGrotesk.txt`、`OFL-Bricolage.txt`
- 新增: `resources/fonts.qrc`
- 新增: `tests/FontAssetsTests.cpp`
- Modify: `CMakeLists.txt`（find_package 补 Gui；fonts.qrc 入 app；新增 FontAssetsTests 目标 + add_test）

**Interfaces:**

- Produces: qrc 别名 `:/fonts/SpaceGrotesk-Medium.ttf`、`:/fonts/SpaceGrotesk-Bold.ttf`、`:/fonts/BricolageGrotesque-Bold.ttf`，family 名 `"Space Grotesk"`/`"Bricolage Grotesque"`。Task 2（注册）、Task 3（令牌）依赖这些字符串。

- [ ] **Step 1: 获取三个静态 ttf + 授权**

放入 `resources/fonts/`。硬性要求：字重 = Space Grotesk 500/700、Bricolage 700；**family 名必须恰为 `"Space Grotesk"`、`"Bricolage Grotesque"`**（Step 6 的守门测试会用 id 作用域校验，拿错立即红）。

来源二选一：
1. 上游静态 ttf（Space Grotesk: floriankarsten/space-grotesk 的 `fonts/ttf/`；Bricolage: ateliertriay/bricolage 的静态实例）；
2. 若只拿到可变字体，用 fonttools 实例化：

```bash
python3 -m pip install --quiet fonttools
fonttools varLib.instancer "SpaceGrotesk[wght].ttf" wght=500 -o resources/fonts/SpaceGrotesk-Medium.ttf
fonttools varLib.instancer "SpaceGrotesk[wght].ttf" wght=700 -o resources/fonts/SpaceGrotesk-Bold.ttf
fonttools varLib.instancer "BricolageGrotesque[opsz,wght].ttf" opsz=24 wght=700 -o resources/fonts/BricolageGrotesque-Bold.ttf
```

两个 OFL 授权文本存为 `resources/fonts/OFL-SpaceGrotesk.txt`、`OFL-Bricolage.txt`（随字体仓库附带的 OFL.txt）。

核验 family 名（可选，守门测试是最终裁判）：

```bash
python3 -c "from fontTools.ttLib import TTFont; import sys; [print(TTFont(f)['name'].getDebugName(1)) for f in sys.argv[1:]]" resources/fonts/*.ttf
```

预期打印 `Space Grotesk` / `Space Grotesk` / `Bricolage Grotesque`。

- [ ] **Step 2: 新建 `resources/fonts.qrc`**

```xml
<RCC>
    <qresource prefix="/">
        <file alias="fonts/SpaceGrotesk-Medium.ttf">fonts/SpaceGrotesk-Medium.ttf</file>
        <file alias="fonts/SpaceGrotesk-Bold.ttf">fonts/SpaceGrotesk-Bold.ttf</file>
        <file alias="fonts/BricolageGrotesque-Bold.ttf">fonts/BricolageGrotesque-Bold.ttf</file>
    </qresource>
</RCC>
```

- [ ] **Step 3: 写守门测试 `tests/FontAssetsTests.cpp`**

```cpp
#include <QGuiApplication>
#include <QFile>
#include <QFontDatabase>
#include <QtTest>

// 字体资源守门：QML 测试不经过 main.cpp、也不链 fonts.qrc，真机之外无人能发现
// qrc 别名写错 / ttf 漏进资源 / 家族名与 Theme 令牌不符。这里用 GUI 实例 + id 作用域
// 校验，把这些盲区变成可测边界。offscreen 平台，无弹窗。
class FontAssetsTests : public QObject
{
    Q_OBJECT

private slots:
    void spaceGroteskMediumRegistersAsSpaceGrotesk();
    void spaceGroteskBoldRegistersAsSpaceGrotesk();
    void bricolageBoldRegistersAsBricolage();

private:
    // family 名取自打包的这个文件本身（applicationFontFamilies(id)），
    // 而非系统全局 families()——否则开发机若已装同名字体会假绿。
    void assertFontFamily(const QString& resourcePath, const QString& expectedFamily)
    {
        QVERIFY2(QFile(resourcePath).exists(),
                 qPrintable(QStringLiteral("资源不存在: ") + resourcePath));
        const int id = QFontDatabase::addApplicationFont(resourcePath);
        QVERIFY2(id != -1,
                 qPrintable(QStringLiteral("注册失败: ") + resourcePath));
        const QStringList families = QFontDatabase::applicationFontFamilies(id);
        QVERIFY2(families.contains(expectedFamily),
                 qPrintable(QStringLiteral("家族名不符，期望 ") + expectedFamily
                            + QStringLiteral("，实际 ") + families.join(QLatin1Char(','))));
    }
};

void FontAssetsTests::spaceGroteskMediumRegistersAsSpaceGrotesk()
{
    assertFontFamily(QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"), QStringLiteral("Space Grotesk"));
}

void FontAssetsTests::spaceGroteskBoldRegistersAsSpaceGrotesk()
{
    assertFontFamily(QStringLiteral(":/fonts/SpaceGrotesk-Bold.ttf"), QStringLiteral("Space Grotesk"));
}

void FontAssetsTests::bricolageBoldRegistersAsBricolage()
{
    assertFontFamily(QStringLiteral(":/fonts/BricolageGrotesque-Bold.ttf"), QStringLiteral("Bricolage Grotesque"));
}

QTEST_MAIN(FontAssetsTests)
#include "FontAssetsTests.moc"
```

- [ ] **Step 4: CMakeLists 接线**

① 第 10 行 `find_package` 补 `Gui`：

```cmake
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick QuickControls2 QuickLayouts QuickTest Sql Test)
```

② APP_SOURCES 里 `resources/qml.qrc` 之后加一行：

```cmake
    resources/qml.qrc
    resources/fonts.qrc
```

③ 在 `add_test(NAME CountdownServiceTests ...)` 之后追加新目标：

```cmake
add_executable(FontAssetsTests
    tests/FontAssetsTests.cpp
    resources/fonts.qrc
)

target_link_libraries(FontAssetsTests PRIVATE
    Qt6::Gui
    Qt6::Test
)

add_test(NAME FontAssetsTests COMMAND FontAssetsTests)
set_tests_properties(FontAssetsTests PROPERTIES
    # 字体校验无需真实窗口；offscreen 保证后台不弹窗（AGENTS.md）。
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)
```

- [ ] **Step 5: 配置 + 构建**

Run: `cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos && cmake --build build 2>&1 | tail -5`
Expected: 配置识别到 `Gui`；`FontAssetsTests` 与 app 均编译通过（rcc 找不到 ttf 会在此报错——若报错说明 Step 1 文件名/路径不符，先修）。

- [ ] **Step 6: 跑守门测试（2 次）**

Run: `QT_QPA_PLATFORM=offscreen ./build/FontAssetsTests`（连续 2 次）
Expected: 3 passed ×2。若家族名断言红 → Step 1 拿到的 ttf 家族名不对，换正确静态实例。

- [ ] **Step 7: 证明守门真的会咬（红绿验证）**

Run: `mv resources/fonts/SpaceGrotesk-Bold.ttf /tmp/sg.bak && cmake --build build 2>&1 | tail -3`
Expected: rcc 因缺文件构建失败——证明 qrc 与磁盘一致性被守住。
Run: `mv /tmp/sg.bak resources/fonts/SpaceGrotesk-Bold.ttf && cmake --build build 2>&1 | tail -2`
Expected: 恢复后构建通过。

- [ ] **Step 8: 提交**

```bash
git add resources/fonts resources/fonts.qrc tests/FontAssetsTests.cpp CMakeLists.txt
git commit -m "打包三款数字字体并加字体资源守门测试"
```

---

### Task 2: main.cpp 注册三字体

**Files:**

- Modify: `src/main.cpp`

**Interfaces:**

- Consumes: Task 1 的 qrc 别名。
- Produces: 运行时 app 内 `"Space Grotesk"`/`"Bricolage Grotesque"` 可用。

- [ ] **Step 1: 加注册代码**

`src/main.cpp` 顶部 include 区加 `#include <QFontDatabase>`。在 `QGuiApplication app(argc, argv);` 之后、`QCoreApplication::setOrganizationName(...)` 之前插入：

```cpp
    // 打包的数字字体：计时数字（Space Grotesk）与统计/倒计时数字（Bricolage）。
    // 注册失败仅告警、不阻断启动——字族解析不到时 Qt 回退系统字，数字仍可读。
    const QStringList bundledFonts = {
        QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Bold.ttf"),
        QStringLiteral(":/fonts/BricolageGrotesque-Bold.ttf"),
    };
    for (const QString& fontPath : bundledFonts) {
        if (QFontDatabase::addApplicationFont(fontPath) == -1) {
            qWarning() << "字体注册失败，将回退系统字:" << fontPath;
        }
    }
```

- [ ] **Step 2: 构建**

Run: `cmake --build build 2>&1 | tail -3`
Expected: 通过。（注册行为的正确性由 Task 1 守门 + Task 6 人工冒烟覆盖；main.cpp 不引入自动测试。）

- [ ] **Step 3: 提交**

```bash
git add src/main.cpp
git commit -m "启动时注册打包数字字体"
```

---

### Task 3: Theme 两个字族令牌

**Files:**

- Modify: `qml/Theme.qml`
- Test: `tests/qml/tst_theme_tokens.qml`

**Interfaces:**

- Produces: `Theme.fontFamilyClock`、`Theme.fontFamilyData`（string）。Task 4/5 引用。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_theme_tokens.qml` 的 `test_scaleTokens()` 之后加：

```qml
    function test_fontFamilyTokens() {
        compare(Theme.fontFamilyClock, "Space Grotesk")
        compare(Theme.fontFamilyData, "Bricolage Grotesque")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`
Expected: FAIL（`fontFamilyClock` undefined）。

- [ ] **Step 3: 实现**

`qml/Theme.qml` 的 `fontDisplay` 定义之后（字号阶梯区末尾）加：

```qml

    // —— 字族（数字英雄；纯拉丁，仅对数字/拉丁可见，中文回退苹方）——
    // 字族名必须与打包 ttf 的家族名一致，FontAssetsTests 用 id 作用域守门。
    readonly property string fontFamilyClock: "Space Grotesk"      // 冷·计时数字
    readonly property string fontFamilyData: "Bricolage Grotesque" // 暖·统计/倒计时数字
```

- [ ] **Step 4: 跑测试确认通过（2 次）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_theme_tokens.qml`（×2）
Expected: 全绿 ×2。

- [ ] **Step 5: 提交**

```bash
git add qml/Theme.qml tests/qml/tst_theme_tokens.qml
git commit -m "Theme 新增数字英雄字族令牌"
```

---

### Task 4: 计时数字套 clock 字族（FocusView 两处 + Sidebar）

**Files:**

- Modify: `qml/views/FocusView.qml`、`qml/components/Sidebar.qml`
- Test: `tests/qml/tst_focus_view.qml`、`tests/qml/tst_sidebar_ui_optimization.qml`

**Interfaces:**

- Consumes: `Theme.fontFamilyClock`。
- Produces: objectName `focusFreeTimeText`、`focusRingTimeText`（Sidebar 复用现有 `sidebarStatus-<marker>`）。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml` 已有测试之后加（实例 id `view`）：

```qml
    function test_timeNumeralsUseClockFamily() {
        var freeText = findChild(view, "focusFreeTimeText")
        verify(freeText)
        compare(freeText.font.family, Theme.fontFamilyClock)

        var ringText = findChild(view, "focusRingTimeText")
        verify(ringText)
        compare(ringText.font.family, Theme.fontFamilyClock)
    }
```

若该文件未导入 Theme，头部加 `import "../../qml"`（该文件第 3 行已有此导入）。

`tests/qml/tst_sidebar_ui_optimization.qml` 已有测试之后加（实例 id `sidebar`；焦点项 marker=`专`）：

```qml
    function test_statusTimeUsesClockFamily() {
        var statusText = findChild(sidebar, "sidebarStatus-专")
        verify(statusText)
        compare(statusText.font.family, Theme.fontFamilyClock)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run（各一次）:
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`
Expected: 新测试 FAIL（findChild 返回 null / family 不符）。

- [ ] **Step 3: 实现——FocusView 两处**

自由专注大字（约 620-629 行）加 `objectName` 与 `font.family`：

```qml
            Text {
                objectName: "focusFreeTimeText"
                Layout.fillWidth: true
                visible: root.state === "free"
                text: root.primaryTimeText()
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontDisplay
                font.family: Theme.fontFamilyClock
                font.bold: true
                color: Theme.accent
                horizontalAlignment: Text.AlignHCenter
            }
```

环内计时读数（约 654-664 行）加 `objectName` 与 `font.family`：

```qml
                    Text {
                        objectName: "focusRingTimeText"
                        Layout.alignment: Qt.AlignHCenter
                        text: root.primaryTimeText()
                        textFormat: Text.PlainText
                        font.pixelSize: root.state === "pomoIdle"
                                        ? (root.panelExpanded ? 42 : 56)
                                        : Theme.fontDisplay
                        font.family: Theme.fontFamilyClock
                        font.bold: true
                        color: root.primaryTimeColor()
                        horizontalAlignment: Text.AlignHCenter
                    }
```

- [ ] **Step 4: 实现——Sidebar 状态时间**

`qml/components/Sidebar.qml` 的 `objectName: "sidebarStatus-" + item.marker` 那个 Text（约 336-343 行），加一行 `font.family`（字重维持 Medium）：

```qml
                Text {
                    objectName: "sidebarStatus-" + item.marker
                    text: item.statusTimeText
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamilyClock
                    font.weight: Font.Medium
                    color: Theme.accent
                }
```

- [ ] **Step 5: 跑测试确认通过（各 2 次）**

Run（各 ×2）:
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`
Expected: 全绿 ×2。

- [ ] **Step 6: 提交**

```bash
git add qml/views/FocusView.qml qml/components/Sidebar.qml tests/qml/tst_focus_view.qml tests/qml/tst_sidebar_ui_optimization.qml
git commit -m "计时数字套用 Space Grotesk 冷字族"
```

---

### Task 5: 数据数字套 data 字族（StatCard + CountdownView）

**Files:**

- Modify: `qml/components/StatCard.qml`、`qml/views/CountdownView.qml`
- Test: `tests/qml/tst_glass_components.qml`、`tests/qml/tst_countdown_ui.qml`

**Interfaces:**

- Consumes: `Theme.fontFamilyData`。
- Produces: objectName `statCardValue`、`countdownHeroDays`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_glass_components.qml` 已有测试之后加（该文件已实例化 StatCard，id `statCard`）：

```qml
    function test_statCardValueUsesDataFamily() {
        var valueText = findChild(statCard, "statCardValue")
        verify(valueText)
        compare(valueText.font.family, Theme.fontFamilyData)
    }
```

`tests/qml/tst_countdown_ui.qml` 已有测试之后加（该文件 CountdownView 实例 id 已核实为 `countdownView`）：

```qml
    function test_countdownHeroDaysUsesDataFamily() {
        var daysText = findChild(countdownView, "countdownHeroDays")
        verify(daysText)
        compare(daysText.font.family, Theme.fontFamilyData)
    }
```

`tst_glass_components.qml` 已导入 Theme；`tst_countdown_ui.qml` **未导入**，需在其头部 import 区加 `import "../../qml"`。

- [ ] **Step 2: 跑测试确认失败**

Run（各一次）:
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_glass_components.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_countdown_ui.qml`
Expected: 新测试 FAIL。

- [ ] **Step 3: 实现——StatCard**

`qml/components/StatCard.qml` 的 `valueText`（约 84-91 行）加 `objectName` 与 `font.family`：

```qml
            Text {
                id: valueText
                objectName: "statCardValue"

                Layout.fillWidth: true
                text: root.value
                font.pixelSize: Theme.fontXxl
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 18
```

（`onTextChanged: valuePulse.restart()` 等其余属性不动。）

- [ ] **Step 4: 实现——CountdownView**

`qml/views/CountdownView.qml` 倒计时天数大字（约 124-131 行）加 `objectName` 与 `font.family`：

```qml
                Text {
                    objectName: "countdownHeroDays"
                    Layout.fillWidth: true
                    text: root.primaryGoal() ? Math.abs(Number(root.primaryGoal().daysRemaining || 0)) : "0"
                    font.pixelSize: Theme.fontDisplay
                    font.family: Theme.fontFamilyData
                    font.weight: Font.Bold
                    color: Theme.accent
                    horizontalAlignment: Text.AlignHCenter
                }
```

- [ ] **Step 5: 跑测试确认通过（各 2 次）**

Run（各 ×2）:
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_glass_components.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_countdown_ui.qml`
Expected: 全绿 ×2。

- [ ] **Step 6: 提交**

```bash
git add qml/components/StatCard.qml qml/views/CountdownView.qml tests/qml/tst_glass_components.qml tests/qml/tst_countdown_ui.qml
git commit -m "统计与倒计时数字套用 Bricolage 暖字族"
```

---

### Task 6: 全量无头回归 + 人工验收

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量无头回归**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 四套测试通过（PomodoroTodoTests、CountdownServiceTests、FontAssetsTests、PomodoroTodoQmlTests）。QML 套件若 tst_ui_optimization.qml 偶发窗口曝光失败，按既有基线重跑一次区分；本计划改动的测试文件必须稳定绿。

- [ ] **Step 2: 人工视觉验收（仅此步用 open，需人眼；非自动步骤）**

Run: `open /Applications/番茄Todo.app`（Step 1 的 `cmake --build build` 已自动部署）
人工确认：① 专注页计时数字呈 Space Grotesk 冷感、侧栏专注状态时间同款；② 统计卡数值与倒计时天数呈 Bricolage 暖感；③ 中文标题/任务仍苹方；④ 启动终端日志无"字体注册失败"`qWarning`。

- [ ] **Step 3: 等宽不抖验收（人工）**

启动一个番茄工作段，看计时从 `25:00` 递减若干秒，确认数字**无左右抖动**。Space Grotesk 数字为表格数字设计，预期不抖；若观察到抖动，给 `focusFreeTimeText`/`focusRingTimeText` 两处加 `font.features: { "tnum": 1 }`（Qt 6.9），重跑 Task 4 测试确认不破坏断言后并入 Task 4 提交或补一提交。

- [ ] **Step 4: 汇报**

向用户汇报四套测试结果与人工验收观感，等待确认是否合并 `type-identity` 回 main（不自行合并）。
