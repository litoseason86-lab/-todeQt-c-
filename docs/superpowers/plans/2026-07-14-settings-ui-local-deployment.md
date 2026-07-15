# 设置 UI 本地部署完善 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有单页长设置弹窗改为适合 macOS 本地部署的五分类设置中心，并补齐持久化失败、键盘操作、减少动效、测试和 `/Applications` 部署验证。

**Architecture:** `SettingsDialog.qml` 只管理弹窗壳、分类、Loader 和状态栏，具体设置拆进 `qml/components/settings/`。所有偏好继续以 `AppSettings` 为唯一数据源，C++ 负责归一化和可靠写入，QML 只负责展示、提交草稿和错误反馈。

**Tech Stack:** Qt 6、QML、Qt Quick Controls Basic、Qt Quick Layouts、MultiEffect、C++17、QSettings、Qt Test、Qt Quick Test、CMake。

## Global Constraints

- 当前 worktree 和分支：`/Users/zerionlito/code/番茄todo`、`ui-optimization-next`；不得创建新 worktree。
- 保持现有 `src/services`、`src/models`、`qml`、`tests` 分层，不迁移整个旧 QML `.qrc` 架构。
- 设置弹窗宽度上限 760 px、高度上限 640 px，父窗口四周保留至少 32 px。
- 项目最小窗口 860×620 下不得裁切或横向滚动。
- 内容区不叠加玻璃卡片；设置弹窗最多一个 `layer.enabled`/`MultiEffect` 效果层。
- 控件命中区最小 44×44 px；正文 15–16 px，说明至少 13 px。
- `reduceMotion` 开启时，设置页所有非必要动画时长为 0。
- 测试固定使用 `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic`，自动流程不执行 `open`。
- 完整构建后必须由现有 `deploy-local-app` 目标部署到 `/Applications/番茄Todo.app`。
- 现有工程通过手写 `resources/qml.qrc` 打包 QML；本次只追加资源项。整体迁移 `qt_add_qml_module` 会扩大范围并破坏当前加载路径，因此不在本计划执行。

---

## File Map

**Create**

- `qml/components/settings/SettingsNavigation.qml`：五分类导航和紧凑布局。
- `qml/components/settings/SettingsSection.qml`：设置分节标题和内容容器。
- `qml/components/settings/SettingsRow.qml`：标签、说明、右侧控件槽位。
- `qml/components/settings/SettingsSwitch.qml`：统一 Switch 外观、焦点和动效门控。
- `qml/components/settings/SettingsThemeChoice.qml`：单个主题缩略图选择项。
- `qml/components/settings/SettingsAppearancePage.qml`：主题、减少动效、计时字体。
- `qml/components/settings/SettingsFocusPage.qml`：专注时长、休息时长、提示音。
- `qml/components/settings/SettingsGeneralPage.qml`：昵称和逻辑日起点。
- `qml/components/settings/SettingsDataPage.qml`：例行、科目、导出和本机数据说明。
- `qml/components/settings/SettingsAboutPage.qml`：应用名、版本和本地能力边界。
- `tests/qml/tst_settings_components.qml`：拆分组件、页面和无障碍入口测试。

**Modify**

- `qml/components/SettingsDialog.qml`：改为弹窗壳、分类 Loader、状态栏和信号转发。
- `qml/components/DurationStepper.qml`：44 px 命中区、Basic import 和可访问性名称。
- `src/services/AppSettings.h/.cpp`：时长归一化、主题默认值、统一可靠写入信号。
- `src/main.cpp`：设置应用版本。
- `CMakeLists.txt`：把 `PROJECT_VERSION` 注入 C++。
- `resources/qml.qrc`：注册新增 QML 文件。
- `tests/ServiceTests.cpp`：设置默认值、损坏值、失败回滚测试。
- `tests/qml/tst_settings_dialog.qml`：新弹窗结构、分类、状态和管理信号测试。

---

### Task 1: 创建设置子组件文件框架

**Files:**
- Create: `qml/components/settings/*.qml`
- Create: `tests/qml/tst_settings_components.qml`
- Modify: `resources/qml.qrc`

**Interfaces:**
- Produces: `SettingsNavigation.currentIndex/categoryRequested(int)`、五个页面的 `appSettingsRef/compact` 属性、`SettingsGeneralPage.commitPendingEdits()`。
- Consumes: `Theme`、现有 `BackgroundWallpaper` 和 `DurationStepper`，本阶段不接业务行为。

- [ ] **Step 1: 写组件可加载测试**

```qml
import QtQuick
import QtTest
import "../../qml/components/settings"

TestCase {
    name: "SettingsComponents"
    when: windowShown

    SettingsNavigation { id: navigation }
    SettingsAppearancePage { id: appearancePage }
    SettingsFocusPage { id: focusPage }
    SettingsGeneralPage { id: generalPage }
    SettingsDataPage { id: dataPage }
    SettingsAboutPage { id: aboutPage }

    function test_publicInterfacesExist() {
        compare(navigation.currentIndex, 0)
        verify(appearancePage.compact !== undefined)
        verify(focusPage.appSettingsRef !== undefined)
        verify(generalPage.commitPendingEdits instanceof Function)
        verify(dataPage.appSettingsRef !== undefined)
        verify(aboutPage.compact !== undefined)
    }
}
```

- [ ] **Step 2: 运行测试并确认缺少类型**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: FAIL，错误包含 `SettingsNavigation is not a type`。

- [ ] **Step 3: 创建只有公共接口的 QML 框架**

每个文件只放 import、根类型、公开属性/信号和 `objectName`。例如：

```qml
import QtQuick
import QtQuick.Controls

FocusScope {
    id: root
    objectName: "settingsAppearancePage"
    property var appSettingsRef: null
    property bool compact: false
}
```

`SettingsNavigation` 明确定义：

```qml
Control {
    id: root
    objectName: "settingsNavigation"
    property int currentIndex: 0
    property bool compact: false
    signal categoryRequested(int index)
}
```

`SettingsGeneralPage.commitPendingEdits()` 框架返回 `true`。把十个新文件逐项加入 `resources/qml.qrc` 的 `/qml/components/settings/` 别名。

- [ ] **Step 4: 运行组件测试和应用构建**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Run: `cmake --build build --target PomodoroTodo -j4`

Expected: 两条命令都成功，新类型可从文件系统测试和 qrc 应用加载。

- [ ] **Step 5: 提交框架**

```bash
git add qml/components/settings resources/qml.qrc tests/qml/tst_settings_components.qml
git commit -m "创建设置中心组件框架"
```

### Task 2: 强化 AppSettings 持久化与时长边界

**Files:**
- Modify: `src/services/AppSettings.h`
- Modify: `src/services/AppSettings.cpp`
- Modify: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces: `settingsWriteSucceeded(QString key)`、`settingsWriteFailed(QString key, QString message)`。
- Produces: `normalizeWorkMinutes(int)`、`normalizeBreakMinutes(int)` 和私有 `writeValue(QString,QVariant)`。
- Consumes: 现有 Q_PROPERTY setter；QML 不依赖 setter 返回值。

- [ ] **Step 1: 写默认值、损坏值和失败回滚测试**

```cpp
void ServiceTests::appSettingsFocusDurationsNormalizeCorruptValues()
{
    QTemporaryDir dir;
    const QString path = dir.filePath(QStringLiteral("settings.ini"));
    QSettings raw(path, QSettings::IniFormat);
    raw.setValue(QStringLiteral("focus/workMinutes"), 999);
    raw.setValue(QStringLiteral("focus/breakMinutes"), -2);
    raw.sync();

    AppSettings settings(path);
    QCOMPARE(settings.workMinutes(), 25);
    QCOMPARE(settings.breakMinutes(), 5);
    settings.setWorkMinutes(180);
    settings.setBreakMinutes(60);
    QCOMPARE(settings.workMinutes(), 180);
    QCOMPARE(settings.breakMinutes(), 60);
}

void ServiceTests::appSettingsWriteFailureDoesNotEmitSuccess()
{
    QTemporaryDir dir;
    AppSettings settings(dir.path()); // 目录不能作为 ini 文件写入，稳定触发 AccessError。
    QSignalSpy successSpy(&settings, &AppSettings::settingsWriteSucceeded);
    QSignalSpy failureSpy(&settings, &AppSettings::settingsWriteFailed);
    QSignalSpy changedSpy(&settings, &AppSettings::soundEnabledChanged);

    settings.setSoundEnabled(false);
    QCOMPARE(successSpy.count(), 0);
    QCOMPARE(failureSpy.count(), 1);
    QCOMPARE(changedSpy.count(), 0);
    QCOMPARE(settings.soundEnabled(), true);
}
```

同步把背景默认值断言从 `warmPaper` 改为 `warm`。

- [ ] **Step 2: 运行 C++ 测试并确认失败**

Run: `cmake --build build --target PomodoroTodoTests -j4 && ctest --test-dir build -R '^PomodoroTodoTests$' --output-on-failure`

Expected: FAIL，缺少新测试槽、失败信号和归一化行为。

- [ ] **Step 3: 实现统一写入辅助函数和归一化**

在头文件增加：

```cpp
signals:
    void settingsWriteSucceeded(const QString& key);
    void settingsWriteFailed(const QString& key, const QString& message);

private:
    static int normalizeWorkMinutes(int minutes);
    static int normalizeBreakMinutes(int minutes);
    bool writeValue(const QString& key, const QVariant& value);
```

核心实现：

```cpp
bool AppSettings::writeValue(const QString& key, const QVariant& value)
{
    const bool hadPrevious = m_settings->contains(key);
    const QVariant previous = m_settings->value(key);
    m_settings->setValue(key, value);
    m_settings->sync();
    if (m_settings->status() == QSettings::NoError) {
        emit settingsWriteSucceeded(key);
        return true;
    }

    if (hadPrevious) {
        m_settings->setValue(key, previous);
    } else {
        m_settings->remove(key);
    }
    m_settings->sync();
    emit settingsWriteFailed(key, QStringLiteral("无法写入本机设置"));
    return false;
}
```

`workMinutes()`/`breakMinutes()` 读取时归一化；setter 归一化后只有 `writeValue()` 成功才发具体 changed 信号。背景默认值改为 `warm`。现有普通偏好 setter 全部改为“成功后发具体 changed 信号”；`setDailyFocusGoal()` 保留现有多键回滚逻辑。

- [ ] **Step 4: 运行服务测试**

Run: `cmake --build build --target PomodoroTodoTests CountdownServiceTests -j4 && ctest --test-dir build -R 'PomodoroTodoTests|CountdownServiceTests' --output-on-failure`

Expected: PASS。

- [ ] **Step 5: 提交持久化修复**

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp tests/ServiceTests.cpp
git commit -m "强化设置持久化与时长边界"
```

### Task 3: 完成弹窗壳、导航和公共行组件

**Files:**
- Modify: `qml/components/SettingsDialog.qml`
- Modify: `qml/components/settings/SettingsNavigation.qml`
- Modify: `qml/components/settings/SettingsSection.qml`
- Modify: `qml/components/settings/SettingsRow.qml`
- Modify: `qml/components/settings/SettingsSwitch.qml`
- Modify: `tests/qml/tst_settings_dialog.qml`
- Modify: `tests/qml/tst_settings_components.qml`

**Interfaces:**
- Consumes: 五页面 `appSettingsRef/compact`、General 页 `commitPendingEdits()`。
- Produces: `SettingsDialog.currentSection`、固定状态栏、原有三个管理信号。

- [ ] **Step 1: 写弹窗尺寸、分类和键盘入口测试**

```qml
function test_shellUsesFiveCategoryNavigation() {
    dialog.open()
    tryCompare(dialog, "opened", true)
    compare(dialog.width, 760)
    verify(dialog.height <= 640)
    var navigation = findChild(dialog, "settingsNavigation")
    verify(navigation)
    compare(findChild(navigation, "settingsCategoryRepeater").count, 5)
    verify(findChild(dialog, "settingsStatusText"))
}

function test_categoryButtonIsKeyboardFocusable() {
    dialog.open()
    var focusButton = findChild(dialog, "settingsCategoryFocus")
    verify(focusButton.activeFocusOnTab)
    focusButton.forceActiveFocus()
    keyClick(Qt.Key_Return)
    compare(dialog.currentSection, 1)
}
```

- [ ] **Step 2: 运行 QML 测试并确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: FAIL，找不到新导航和状态栏。

- [ ] **Step 3: 实现公共组件与双栏壳**

`SettingsDialog` 使用 `RowLayout`：168 px `SettingsNavigation` + 右侧 `ColumnLayout`。右侧包含固定页头、`ScrollView` 内的单一 `Loader`、固定状态栏。页面组件通过具名 `Component` 提供，Loader 访问必须检查 `status === Loader.Ready`。

分类切换核心逻辑：

```qml
function requestSection(index) {
    if (pageLoader.status === Loader.Ready && pageLoader.item
            && typeof pageLoader.item.commitPendingEdits === "function"
            && !pageLoader.item.commitPendingEdits()) {
        return
    }
    root.currentSection = index
}
```

`SettingsNavigation` 使用五个 `Button`，objectName 依次为 `settingsCategoryAppearance`、`settingsCategoryFocus`、`settingsCategoryGeneral`、`settingsCategoryData`、`settingsCategoryAbout`。按钮最小高度 44，`activeFocus` 时显示 `Theme.accent` 焦点边框。

- [ ] **Step 4: 运行设置 QML 测试**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: PASS，且输出不含 `Unable to assign [undefined]`。

- [ ] **Step 5: 提交弹窗壳**

```bash
git add qml/components/SettingsDialog.qml qml/components/settings tests/qml/tst_settings_dialog.qml tests/qml/tst_settings_components.qml
git commit -m "重构设置弹窗分类与公共组件"
```

### Task 4: 完成外观页

**Files:**
- Modify: `qml/components/settings/SettingsAppearancePage.qml`
- Modify: `qml/components/settings/SettingsThemeChoice.qml`
- Modify: `tests/qml/tst_settings_components.qml`

**Interfaces:**
- Consumes: `Theme.themes`、`Theme.migrateThemeId()`、`appSettingsRef.backgroundTheme/reduceMotion/slimClockFont`。
- Produces: 原有主题、开关 objectName，供回归测试继续定位。

- [ ] **Step 1: 写旧主题、缩略图和动效测试**

```qml
function test_legacyThemeStillShowsWarmSelected() {
    appSettingsMock.backgroundTheme = "warmPaper"
    appearancePage.appSettingsRef = appSettingsMock
    var warm = findChild(appearancePage, "settingsThemeChoice-warm")
    verify(warm.checked)
}

function test_reduceMotionDisablesSwitchAnimation() {
    appSettingsMock.reduceMotion = true
    compare(findChild(appearancePage, "settingsReduceMotionSwitch").animationDuration, 0)
}
```

- [ ] **Step 2: 运行 QML 测试并确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: FAIL，新页面尚未渲染主题与开关。

- [ ] **Step 3: 实现响应式主题画廊和外观开关**

画廊使用 `GridLayout { columns: root.compact ? 2 : 3 }`。`SettingsThemeChoice` 根为可聚焦 `Button`，`checkable: true`，选中判断为：

```qml
checked: Theme.migrateThemeId(root.appSettingsRef
        ? root.appSettingsRef.backgroundTheme : "warm") === root.themeId
```

缩略图继续传 `requestedSourceSize: Qt.size(154, 66)`，并保留候选主题自身的 `glassCardForMode()` 预览。开关统一使用 `SettingsSwitch`，其 `animationDuration` 为 `reduceMotion ? 0 : 120`。

- [ ] **Step 4: 运行 QML 测试**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: PASS。

- [ ] **Step 5: 提交外观页**

```bash
git add qml/components/settings/SettingsAppearancePage.qml qml/components/settings/SettingsThemeChoice.qml tests/qml
git commit -m "完善设置中心外观页"
```

### Task 5: 完成专注页与通用页

**Files:**
- Modify: `qml/components/settings/SettingsFocusPage.qml`
- Modify: `qml/components/settings/SettingsGeneralPage.qml`
- Modify: `qml/components/DurationStepper.qml`
- Modify: `tests/qml/tst_settings_components.qml`

**Interfaces:**
- Consumes: `workMinutes`、`breakMinutes`、`soundEnabled`、`nickname`、`dayStartHour`。
- Produces: `SettingsGeneralPage.commitPendingEdits(): bool`。

- [ ] **Step 1: 写时长、昵称草稿和逻辑日测试**

```qml
function test_focusDurationsWriteSharedSettings() {
    mouseClick(findChild(focusPage, "settingsWorkMinutesPlus"))
    compare(appSettingsMock.workMinutes, 61)
    mouseClick(findChild(focusPage, "settingsBreakMinutesMinus"))
    compare(appSettingsMock.breakMinutes, 9)
}

function test_generalPageCommitsNicknameDraft() {
    var field = findChild(generalPage, "settingsNicknameField")
    field.text = "  小番茄  "
    verify(generalPage.commitPendingEdits())
    compare(appSettingsMock.nickname, "小番茄")
}
```

测试 mock 增加 `workMinutes: 60`、`breakMinutes: 10`、`nickname: ""` 和失败模拟属性。

- [ ] **Step 2: 运行 QML 测试并确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: FAIL，页面控件尚不存在。

- [ ] **Step 3: 实现专注和通用设置**

`DurationStepper` 改为 `QtQuick.Controls.Basic`，加 `accessibleName` 属性，两个按钮 `implicitWidth/implicitHeight` 均至少 44。

通用页维护 `property string nicknameDraft`；提交逻辑：

```qml
function commitPendingEdits() {
    var normalized = nicknameDraft.trim()
    if (!root.appSettingsRef || normalized === root.appSettingsRef.nickname) {
        return true
    }
    root.appSettingsRef.nickname = normalized
    if (root.appSettingsRef.nickname === normalized) {
        nicknameDraft = normalized
        return true
    }
    return false
}
```

失败时不清空草稿，由 `SettingsDialog` 的写入失败 Connections 显示错误并留在当前页。

- [ ] **Step 4: 运行 QML 测试**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: PASS。

- [ ] **Step 5: 提交专注和通用页**

```bash
git add qml/components/settings/SettingsFocusPage.qml qml/components/settings/SettingsGeneralPage.qml qml/components/DurationStepper.qml tests/qml
git commit -m "补全专注与通用设置"
```

### Task 6: 完成数据页、关于页和版本接线

**Files:**
- Modify: `qml/components/settings/SettingsDataPage.qml`
- Modify: `qml/components/settings/SettingsAboutPage.qml`
- Modify: `qml/components/SettingsDialog.qml`
- Modify: `src/main.cpp`
- Modify: `CMakeLists.txt`
- Modify: `tests/qml/tst_settings_components.qml`

**Interfaces:**
- Produces: 数据页 `routineRequested/categoryRequested/exportRequested`。
- Consumes: `Qt.application.version`，由 CMake `PROJECT_VERSION` 设置。

- [ ] **Step 1: 写管理信号和版本测试**

```qml
function test_dataActionsEmitSignals() {
    var routineSpy = createTemporaryObject(signalSpyComponent, testCase, {
        target: dataPage, signalName: "routineRequested"
    })
    mouseClick(findChild(dataPage, "settingsManageRoutine"))
    compare(routineSpy.count, 1)
}

function test_aboutUsesApplicationVersion() {
    compare(findChild(aboutPage, "settingsAboutVersion").text,
            Qt.application.version)
}
```

- [ ] **Step 2: 运行 QML 测试并确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: FAIL，管理按钮和版本文本尚不存在。

- [ ] **Step 3: 实现页面与构建版本注入**

数据页使用最小高度 44 的 `Button` 行并发出三个信号；`SettingsDialog` 关闭自身后转发原有信号。关于页显示 `Qt.application.version`。

在 CMake 增加：

```cmake
target_compile_definitions(PomodoroTodo PRIVATE
    POMODORO_TODO_VERSION="${PROJECT_VERSION}"
)
```

在 `main.cpp` 组织名设置附近增加：

```cpp
QCoreApplication::setApplicationVersion(QStringLiteral(POMODORO_TODO_VERSION));
```

- [ ] **Step 4: 重新配置、构建并运行 QML 测试**

Run: `cmake -S . -B build && cmake --build build --target PomodoroTodo -j4`

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: PASS，应用版本为 `0.1.0`。

- [ ] **Step 5: 提交数据、关于和版本接线**

```bash
git add qml/components/settings qml/components/SettingsDialog.qml src/main.cpp CMakeLists.txt tests/qml
git commit -m "完成数据关于页面与版本接线"
```

### Task 7: 接入写入状态、减少动效和最终无障碍门禁

**Files:**
- Modify: `qml/components/SettingsDialog.qml`
- Modify: `qml/components/settings/*.qml`
- Modify: `tests/qml/tst_settings_dialog.qml`
- Modify: `tests/qml/tst_settings_components.qml`

**Interfaces:**
- Consumes: `AppSettings.settingsWriteSucceeded/settingsWriteFailed`。
- Produces: 固定成功/失败状态栏和完整键盘路径。

- [ ] **Step 1: 写保存失败、减少动效和 44 px 测试**

```qml
function test_writeFailureStaysVisible() {
    dialog.open()
    appSettingsMock.settingsWriteFailed("appearance/reduceMotion", "无法写入本机设置")
    var status = findChild(dialog, "settingsStatusText")
    compare(status.text, "无法保存设置，请检查系统权限后重试")
    compare(status.visible, true)
}

function test_controlsMeetMinimumTarget() {
    verify(findChild(dialog, "settingsCloseButton").implicitHeight >= 44)
    verify(findChild(dialog, "settingsCategoryAppearance").implicitHeight >= 44)
}
```

- [ ] **Step 2: 运行 QML 测试并确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Expected: FAIL，状态栏尚未监听后端信号或部分控件小于 44 px。

- [ ] **Step 3: 实现状态 Connections、动画门控和可访问性**

```qml
Connections {
    target: root.appSettingsRef
    function onSettingsWriteSucceeded(key) {
        root.statusIsError = false
        root.statusText = "所有设置已保存到本机"
    }
    function onSettingsWriteFailed(key, message) {
        root.statusIsError = true
        root.statusText = "无法保存设置，请检查系统权限后重试"
    }
}
```

弹窗进入/退出和分类过渡的 duration 绑定 `reduceMotion ? 0 : 正常时长`。所有自定义控件补 `Accessible.name`、`Accessible.role`、`activeFocusOnTab` 和 `activeFocus` 焦点环。说明文字统一为 13 px 且使用 `Theme.inkSoft`；正文使用 15 px。

- [ ] **Step 4: 运行 QML 全量测试和 qmllint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`

Run: `qmllint -I qml -I qml/components qml/components/SettingsDialog.qml qml/components/settings/*.qml qml/components/DurationStepper.qml`

Expected: 测试 PASS；qmllint 不产生新增 warning/error。

- [ ] **Step 5: 提交可靠性和无障碍完善**

```bash
git add qml/components/SettingsDialog.qml qml/components/settings qml/components/DurationStepper.qml tests/qml
git commit -m "完善设置写入反馈与无障碍交互"
```

### Task 8: 完整验证、构建和本地部署

**Files:**
- Verify only; 不修改 `build/` 生成物。

**Interfaces:**
- Consumes: 前七个任务的全部交付。
- Produces: `/Applications/番茄Todo.app` 最新本地应用包和测试证据。

- [ ] **Step 1: 检查工作树和差异**

Run: `git status --short && git diff --check HEAD`

Expected: 无未提交源码，diff check 无输出。

- [ ] **Step 2: 完整构建**

Run: `cmake -S . -B build && cmake --build build -j4`

Expected: 成功构建所有目标；`deploy-local-app` 自动执行并刷新 LaunchServices 索引。

- [ ] **Step 3: 全量测试**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`

Expected: 100% tests passed，输出不含 QML 运行警告。

- [ ] **Step 4: 核对部署包**

Run: `stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' build/PomodoroTodo.app/Contents/MacOS/PomodoroTodo /Applications/番茄Todo.app/Contents/MacOS/PomodoroTodo`

Expected: 两个二进制时间戳一致且对应本次构建。

- [ ] **Step 5: 最终确认分支状态**

Run: `git status --short --branch && git log -8 --oneline`

Expected: 工作树干净，日志包含本计划各任务的中文提交。若验证发现源码问题，返回问题所属任务修正、运行该任务测试并使用该任务的提交范围提交，不创建含糊的“最终修正”大提交。不得自动执行 `open /Applications/番茄Todo.app`；用户退出旧进程后手动重启进行视觉验收。
