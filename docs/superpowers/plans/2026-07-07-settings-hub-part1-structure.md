# 设置中心化 + 侧栏减负 · 计划一（结构迁移 + 存储）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把设置弹窗升级为三段式控制台（背景主题 + 偏好开关 + 管理入口），侧栏删掉三个管理项与"三阶段"孤儿标签，并新增 `reduceMotion` 偏好（本计划仅存取，动画门控见计划二）。

**Architecture:** AppSettings 加 `reduceMotion`（镜像 `soundEnabled`）；SettingsDialog 内容进 ScrollView 防溢出，新增两开关（绑 soundEnabled/reduceMotion）+ 三管理行（emit 信号）；Sidebar 删项删标签删信号；MainWindow 把三个管理入口从侧栏迁到设置弹窗。

**Tech Stack:** Qt 6.9 / C++17 / QML / QSettings / Qt Test + qmltestrunner

**Depends on:** 无（背景/排版已在 main）。本计划在 `ui-polish` 分支（#1 已提交于此）。

## Global Constraints

- 注释、提交说明一律中文；注释解释"为什么/边界"（AGENTS.md）。
- **自动流程一律无头**：C++ `QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests <fn>`；QML `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`。禁含 `open`。验收 = 连续 2 次全绿。
- 构建：`cmake --build build`（已配置）；**不得改 build/**。
- 缺 `appSettingsRef` 时开关只显示不写、不崩（同画廊守卫）。

---

### Task 1: AppSettings 新增 reduceMotion

**Files:**

- Modify: `src/services/AppSettings.h`、`src/services/AppSettings.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**

- Produces: `Q_PROPERTY(bool reduceMotion ...)`，键 `appearance/reduceMotion`，默认 `false`，信号 `reduceMotionChanged()`。计划二动画门控读它。

- [ ] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` 私有槽区（`appSettingsSameValueDoesNotEmit();` 之后）加声明：

```cpp
    void appSettingsReduceMotionRoundTrip();
```

在 `appSettingsSameValueDoesNotEmit()` 实现之后加：

```cpp
void ServiceTests::appSettingsReduceMotionRoundTrip()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    {
        AppSettings settings(path);
        QCOMPARE(settings.reduceMotion(), false); // 默认关

        QSignalSpy spy(&settings, &AppSettings::reduceMotionChanged);
        settings.setReduceMotion(true);
        QCOMPARE(settings.reduceMotion(), true);
        QCOMPARE(spy.count(), 1);
        settings.setReduceMotion(true); // 同值不重复发
        QCOMPARE(spy.count(), 1);
    }
    AppSettings reloaded(path);
    QCOMPARE(reloaded.reduceMotion(), true); // 持久化
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cmake --build build 2>&1 | tail -4`
Expected: 编译失败，`no member named 'reduceMotion'`。

- [ ] **Step 3: 实现**

`src/services/AppSettings.h`——`Q_PROPERTY(bool soundEnabled ...)` 之后加：

```cpp
    Q_PROPERTY(bool reduceMotion READ reduceMotion WRITE setReduceMotion NOTIFY reduceMotionChanged)
```

public 区 `setSoundEnabled` 之后加：

```cpp
    bool reduceMotion() const;
    void setReduceMotion(bool enabled);
```

signals 区 `soundEnabledChanged()` 之后加：

```cpp
    void reduceMotionChanged();
```

`src/services/AppSettings.cpp`——匿名命名空间 `kSoundEnabledKey` 之后加：

```cpp
const auto kReduceMotionKey = QStringLiteral("appearance/reduceMotion");
```

文件末尾加：

```cpp
bool AppSettings::reduceMotion() const
{
    return m_settings->value(kReduceMotionKey, false).toBool();
}

void AppSettings::setReduceMotion(bool enabled)
{
    if (reduceMotion() == enabled) {
        return;
    }
    m_settings->setValue(kReduceMotionKey, enabled);
    m_settings->sync();
    emit reduceMotionChanged();
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests appSettingsReduceMotionRoundTrip`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp tests/ServiceTests.cpp
git commit -m "AppSettings 新增减少动效偏好 reduceMotion"
```

---

### Task 2: SettingsDialog 三段化（偏好开关 + 管理行 + 滚动）

**Files:**

- Modify: `qml/components/SettingsDialog.qml`
- Test: `tests/qml/tst_settings_dialog.qml`

**Interfaces:**

- Consumes: `appSettingsRef.soundEnabled`、`appSettingsRef.reduceMotion`。
- Produces: `signal routineRequested`、`categoryRequested`、`exportRequested`；objectName `settingsSoundSwitch`(+Track/Thumb)、`settingsReduceMotionSwitch`(+Track/Thumb)、`settingsManageRoutine`/`Category`/`Export`、`settingsCloseButton`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_settings_dialog.qml` 已有测试之后加（该文件已有 `appSettingsMock`、`dialog` 实例；给 mock 补 `soundEnabled`/`reduceMotion` 属性）：

```qml
    function test_soundSwitchBindsSetting() {
        appSettingsMock.soundEnabled = true
        dialog.open(); wait(20)
        var sw = findChild(dialog, "settingsSoundSwitch")
        verify(sw)
        compare(sw.checked, true)
        sw.toggle(); sw.toggled()
        compare(appSettingsMock.soundEnabled, false)
    }

    function test_reduceMotionSwitchBindsSetting() {
        appSettingsMock.reduceMotion = false
        dialog.open(); wait(20)
        var sw = findChild(dialog, "settingsReduceMotionSwitch")
        verify(sw)
        compare(sw.checked, false)
        sw.toggle(); sw.toggled()
        compare(appSettingsMock.reduceMotion, true)
    }

    function test_manageRowsEmitSignals() {
        dialog.open(); wait(20)
        var routineSpy = createTemporaryObject(signalSpyComponent, testCase, { target: dialog, signalName: "routineRequested" })
        var row = findChild(dialog, "settingsManageRoutine")
        verify(row)
        mouseClick(row)
        compare(routineSpy.count, 1)
    }

    function test_closeButtonHasObjectName() {
        dialog.open(); wait(20)
        verify(findChild(dialog, "settingsCloseButton"))
    }
```

文件顶部若无 SignalSpy 组件工厂，加：

```qml
    Component { id: signalSpyComponent; SignalSpy {} }
```

给 `appSettingsMock` 补属性（若缺）：`property bool soundEnabled: true` / `property bool reduceMotion: false`。

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`
Expected: 新测试 FAIL（控件不存在）。

- [ ] **Step 3: 实现——SettingsDialog 改造**

在 `import ".."` 之后确保有 `import QtQuick.Controls.Basic`（已有）。信号加在 `property var appSettingsRef: null` 之后：

```qml
    signal routineRequested
    signal categoryRequested
    signal exportRequested
```

`height` 改为封顶（原 `height: panel.implicitHeight`）：

```qml
    height: Math.min(contentColumn.implicitHeight,
                     parent ? parent.height - Theme.space32 * 2 : contentColumn.implicitHeight)
```

把 `contentItem: ColumnLayout { id: contentColumn ... }` 整体包进 ScrollView（ColumnLayout 内容不动，仅新增外层 + 在画廊 GridLayout 与"关闭"Button 之间插入两段）。新的 contentItem 外壳：

```qml
    contentItem: ScrollView {
        id: settingsScroll

        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        // 复用 WeekPlanView/MonthGoalView 的暖色主题化滚动条，不重设计。
        ScrollBar.vertical: ScrollBar {
            id: settingsScrollBar
            policy: ScrollBar.AsNeeded
            width: 8
            contentItem: Rectangle {
                implicitWidth: 4
                radius: Theme.radiusSm
                color: settingsScrollBar.pressed || settingsScrollBar.hovered ? Theme.accent : Theme.border
            }
            background: Rectangle { color: "transparent" }
        }

        ColumnLayout {
            id: contentColumn

            width: settingsScroll.availableWidth
            spacing: Theme.space12

            // …… 原“设置”标题、“背景主题”小标题、画廊 GridLayout 保持不动 ……
        }
    }
```

在画廊 GridLayout 之后、"关闭"Button 之前插入偏好段与管理段：

```qml
        Text {
            Layout.leftMargin: Theme.space16
            text: "偏好"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            font.weight: Font.Bold
        }

        PreferenceSwitchRow {
            label: "提示音"
            switchName: "settingsSoundSwitch"
            checkedValue: root.appSettingsRef ? root.appSettingsRef.soundEnabled : true
            onToggledTo: function (v) { if (root.appSettingsRef) root.appSettingsRef.soundEnabled = v }
        }

        PreferenceSwitchRow {
            label: "减少动效"
            switchName: "settingsReduceMotionSwitch"
            checkedValue: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
            onToggledTo: function (v) { if (root.appSettingsRef) root.appSettingsRef.reduceMotion = v }
        }

        Text {
            Layout.leftMargin: Theme.space16
            text: "管理"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            font.weight: Font.Bold
        }

        ManageEntryRow {
            label: "每日例行"
            rowName: "settingsManageRoutine"
            onActivated: { root.close(); root.routineRequested() }
        }

        ManageEntryRow {
            label: "科目管理"
            rowName: "settingsManageCategory"
            onActivated: { root.close(); root.categoryRequested() }
        }

        ManageEntryRow {
            label: "数据导出"
            rowName: "settingsManageExport"
            onActivated: { root.close(); root.exportRequested() }
        }
```

"关闭"Button 加 `objectName: "settingsCloseButton"`（在其 `id: closeButton` 之后）。

在 Popup 根部（`background` 之前或之后）加两个内联组件定义：

```qml
    // 偏好开关行：左标签 + 右自绘 Switch（暖纸令牌，非 Basic 默认外观）。
    component PreferenceSwitchRow: RowLayout {
        id: prefRow

        property string label: ""
        property string switchName: ""
        property bool checkedValue: false
        property var onToggledTo: function (v) {}

        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16

        Text {
            Layout.fillWidth: true
            text: prefRow.label
            textFormat: Text.PlainText
            color: Theme.ink
            font.pixelSize: Theme.fontMd
        }

        Switch {
            id: prefSwitch
            objectName: prefRow.switchName
            checked: prefRow.checkedValue
            onToggled: prefRow.onToggledTo(checked)

            indicator: Rectangle {
                objectName: prefRow.switchName + "Track"
                implicitWidth: 40
                implicitHeight: 22
                radius: 11
                color: prefSwitch.checked ? Theme.accent : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1

                Rectangle {
                    objectName: prefRow.switchName + "Thumb"
                    x: prefSwitch.checked ? parent.width - width - 2 : 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    radius: 9
                    color: Theme.surface

                    Behavior on x {
                        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                    }
                }
            }

            contentItem: Item {}
        }
    }

    // 管理入口行：整行可点，右侧 › 提示可进入。
    component ManageEntryRow: Rectangle {
        id: manageRow

        property string label: ""
        property string rowName: ""
        signal activated

        objectName: manageRow.rowName
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16
        implicitHeight: 40
        radius: Theme.radiusMd
        color: manageHover.hovered ? Theme.surfaceSunken : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.space8
            anchors.rightMargin: Theme.space8

            Text {
                Layout.fillWidth: true
                text: manageRow.label
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Text {
                text: "›"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontLg
            }
        }

        HoverHandler { id: manageHover }
        TapHandler { onTapped: manageRow.activated() }
    }
```

（`pragma ComponentBehavior: Bound` 文件已有，内联组件引用 root 合规。）

- [ ] **Step 4: 跑测试确认通过（2 次）+ lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`（×2）
Expected: 全绿 ×2（含既有画廊测试不回归）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/SettingsDialog.qml`
Expected: 零警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/SettingsDialog.qml tests/qml/tst_settings_dialog.qml
git commit -m "设置弹窗三段化：偏好开关与管理入口并滚动防溢出"
```

---

### Task 3: Sidebar 删三项 + 删标签 + 改写旧测试

**Files:**

- Modify: `qml/components/Sidebar.qml`
- Test: `tests/qml/tst_sidebar_ui_optimization.qml`

**Interfaces:**

- Produces: 侧栏不再有 例行/科目/导出 项与"三阶段"标签；保留 `settingsRequested`。

- [ ] **Step 1: 改写失败测试**

`tests/qml/tst_sidebar_ui_optimization.qml` 的 `test_dividerAndVersionStyles()` 整体替换为（保留 divider 断言，删 version，新增"三项与标签已不存在"）：

```qml
    function test_dividerStyleAndManagementRemoved() {
        var divider = findDivider();
        verify(divider !== null);
        compare(divider.height, 1);
        verify(Qt.colorEqual(divider.color, Theme.border));
        compare(divider.opacity, 0.8);

        // 管理项已迁入设置弹窗、“三阶段”孤儿标签已删。
        verify(findText("三阶段") === null, "三阶段标签应已删除");
        verify(findChild(sidebar, "sidebarItem-例") === null, "每日例行应已移出侧栏");
        verify(findChild(sidebar, "sidebarItem-科") === null, "科目管理应已移出侧栏");
        verify(findChild(sidebar, "sidebarItem-导") === null, "数据导出应已移出侧栏");
        verify(findChild(sidebar, "sidebarItem-设") !== null, "设置项应保留");
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`
Expected: 新测试 FAIL（三项仍在、标签仍在）。

- [ ] **Step 3: 实现——删项删标签删信号**

`qml/components/Sidebar.qml`：

1. 删除三个 SidebarItem（"每日例行"marker 例、"科目管理"marker 科、"数据导出"marker 导）整段；
2. 删除其后的 `Text { text: "三阶段" ... }` 整段；
3. 删除信号声明 `signal dailyRoutineRequested`、`signal categoryManagementRequested`、`signal dataExportRequested`；
4. 保留"设置"SidebarItem 与 `signal settingsRequested`；
5. grep 确认 `categoryManagerRef`/`exportServiceRef` 是否仍被引用：

```bash
grep -n "categoryManagerRef\|exportServiceRef" qml/components/Sidebar.qml
```

若仅剩属性声明、无其它使用，一并删除这两个属性声明（避免死属性）；MainWindow 注入处相应删除（见 Task 4）。

- [ ] **Step 4: 跑测试确认通过（2 次）+ lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/Sidebar.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/Sidebar.qml tests/qml/tst_sidebar_ui_optimization.qml
git commit -m "侧栏移除管理项与三阶段标签，迁往设置弹窗"
```

---

### Task 4: MainWindow 接线迁移

**Files:**

- Modify: `qml/MainWindow.qml`
- Test: `tests/qml/tst_mainwindow_ui_optimization.qml`

**Interfaces:**

- Consumes: SettingsDialog 的 `routineRequested`/`categoryRequested`/`exportRequested`（Task 2）；Sidebar 已删的三信号（Task 3）。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_mainwindow_ui_optimization.qml` 已有测试之后加（实例 id `mainWindow`）。经 SettingsDialog 实例发 `routineRequested`，断言 MainWindow 接线打开了 RoutineDialog——依赖实现步给两个实例加 objectName（`settingsDialog` / `routineDialogRoot`）：

```qml
    function test_settingsRoutineSignalOpensRoutineDialog() {
        var settings = findChild(mainWindow, "settingsDialog")
        verify(settings, "SettingsDialog 实例应存在")
        var routine = findChild(mainWindow, "routineDialogRoot")
        verify(routine, "RoutineDialog 实例应存在")

        verify(routine.opened === false)
        settings.routineRequested()
        verify(routine.opened === true, "管理入口信号应打开对应弹窗")
        routine.close()
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`
Expected: FAIL（objectName 未加 / 接线未迁）。

- [ ] **Step 3: 实现——迁移接线**

`qml/MainWindow.qml` 的 Sidebar 实例：删除三行处理器

```qml
            onCategoryManagementRequested: categoryDialog.open()
            onDailyRoutineRequested: routineDialog.open()
            onDataExportRequested: exportDialog.open()
```

并删除 Sidebar 实例上的 `categoryManagerRef: categoryManager`、`exportServiceRef: exportService` 注入（若 Task 3 已删这两个属性）。

SettingsDialog 实例改为（加 objectName + 三个信号处理器）：

```qml
    SettingsDialog {
        id: settingsDialog
        objectName: "settingsDialog"

        parent: root
        appSettingsRef: root.appSettingsRef

        onRoutineRequested: routineDialog.open()
        onCategoryRequested: categoryDialog.open()
        onExportRequested: exportDialog.open()
    }
```

给 `RoutineDialog` 实例加 `objectName: "routineDialogRoot"`（供测试断言 opened）。

- [ ] **Step 4: 跑测试确认通过（2 次）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`（×2）
Expected: 全绿 ×2。

- [ ] **Step 5: 提交**

```bash
git add qml/MainWindow.qml tests/qml/tst_mainwindow_ui_optimization.qml
git commit -m "主窗口把管理入口从侧栏迁到设置弹窗"
```

---

### Task 5: 全量无头回归

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量构建 + 四套测试**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 4/4 通过。QML 套件若 tst_ui_optimization.qml 偶发窗口曝光失败，重跑一次区分；本计划改动的测试文件须稳定绿。

- [ ] **Step 2: 人工验收（仅此步用 open，需人眼）**

Run: `open /Applications/番茄Todo.app`
确认：侧栏只剩 6 视图 + 设置（无 例行/科目/导出/三阶段）；设置弹窗有 背景主题/偏好（提示音+减少动效）/管理（三入口 ›）三段；小窗口下弹窗可滚动到"关闭"；点管理三入口能关设置并打开对应弹窗；提示音开关与专注页 🔔 同步。（减少动效开关本阶段仅存储，动画未接——计划二处理。）
