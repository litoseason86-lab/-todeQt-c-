# 专注 UX 改进第一部分：AppSettings 服务 + 启动直达与记忆 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建 AppSettings 偏好服务；任务列表「开始专注」记住上次模式一键直达（自由直接计时 / 番茄进待机带任务）；时长记忆；冲突时自动跳转专注页。

**Architecture:** `AppSettings`（QSettings 薄封装）注册为上下文属性 `appSettings`；三个任务视图不再直接调 `focusTimer.startFocus`，统一上抛信号由 MainWindow 的 `startFocusForTask` 集中决策；FocusView 注入 `settings` 属性并新增 `enterPomodoroWithTask`。

**Tech Stack:** Qt 6.9 / C++17 / QSettings / Qt Quick(QML) / Qt Test / CMake。

**对应规格:** `docs/superpowers/specs/2026-07-05-focus-ux-improvements-design.md` 的「结构性决策」「①⑤」「④（跳转部分；toast 文案在第二部分）」。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；每个任务改完跑构建与相关测试再提交。
- 配置：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`；构建：`cmake --build build`；C++ 测试：`ctest --test-dir build -R PomodoroTodoTests --output-on-failure`；QML 测试：`ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`；单文件 QML：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<file>.qml`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`。
- 开始前从 `main` 创建并检出分支 `focus-ux-improvements`（若已存在则直接检出）。
- **QML 测试纪律**：绝不断言 `something.visible === true`（级联可见性在本沙箱不可靠，见项目记忆）；断言驱动它的源头布尔/字符串属性。
- QML 测试整套跑存在既有偶发失败（`tst_ui_optimization.qml` 粒子计数，与本计划无关）；判定标准以**单文件 qmltestrunner 连跑 2 次全绿**为准，整套跑失败时先确认失败点是否属于本计划改动的文件。
- 文案用裸中文（不加 `qsTr()`）。

---

### Task 1: AppSettings 服务（C++）

**Files:**
- Create: `src/services/AppSettings.h`
- Create: `src/services/AppSettings.cpp`
- Modify: `CMakeLists.txt`（APP_SOURCES 与 PomodoroTodoTests 各加一行）
- Modify: `src/main.cpp`（include + 上下文属性）
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces:
  - 类 `AppSettings`，构造 `explicit AppSettings(const QString& settingsFilePath = QString(), QObject* parent = nullptr)`（空路径 → 默认 QSettings；给路径 → IniFormat，测试用）
  - 单例 `static AppSettings* instance()`
  - 属性（均带 WRITE/NOTIFY）：`int lastMode`（默认 0）、`int workMinutes`（默认 25）、`int breakMinutes`（默认 5）、`bool soundEnabled`（默认 true）
  - QML 上下文属性名：`appSettings`

- [x] **Step 1: 写失败测试**

在 `tests/ServiceTests.cpp` 顶部 include 区加入：

```cpp
#include "../src/services/AppSettings.h"
#include <QTemporaryDir>
```

在 `private slots:` 声明区加入：

```cpp
    void appSettingsDefaultsAndRoundTrip();
    void appSettingsSameValueDoesNotEmit();
```

在实现区加入：

```cpp
void ServiceTests::appSettingsDefaultsAndRoundTrip()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        // 默认值
        QCOMPARE(settings.lastMode(), 0);
        QCOMPARE(settings.workMinutes(), 25);
        QCOMPARE(settings.breakMinutes(), 5);
        QCOMPARE(settings.soundEnabled(), true);

        QSignalSpy modeSpy(&settings, &AppSettings::lastModeChanged);
        QSignalSpy workSpy(&settings, &AppSettings::workMinutesChanged);
        settings.setLastMode(1);
        settings.setWorkMinutes(45);
        settings.setBreakMinutes(10);
        settings.setSoundEnabled(false);
        QCOMPARE(modeSpy.count(), 1);
        QCOMPARE(workSpy.count(), 1);
    }

    // 重新打开同一文件，值必须已持久化。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.lastMode(), 1);
    QCOMPARE(reloaded.workMinutes(), 45);
    QCOMPARE(reloaded.breakMinutes(), 10);
    QCOMPARE(reloaded.soundEnabled(), false);
}

void ServiceTests::appSettingsSameValueDoesNotEmit()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    AppSettings settings(dir.filePath(QStringLiteral("settings.ini")));

    QSignalSpy modeSpy(&settings, &AppSettings::lastModeChanged);
    settings.setLastMode(0); // 与默认值相同
    QCOMPARE(modeSpy.count(), 0);
}
```

同时在 `CMakeLists.txt` 的两处源列表加 `src/services/AppSettings.cpp`：`APP_SOURCES`（`src/services/CountdownService.cpp` 之前一行）与 `PomodoroTodoTests` 的源列表（`src/services/FocusHistoryService.cpp` 之后一行）。

- [x] **Step 2: 运行测试确认编译失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误 `AppSettings.h: No such file or directory`（测试先行，实现未建）。

- [x] **Step 3: 写实现**

`src/services/AppSettings.h`：

```cpp
#ifndef APPSETTINGS_H
#define APPSETTINGS_H

#include <QObject>
#include <QSettings>

// 用户偏好的唯一入口：QSettings 薄封装。
// 测试传入独立 ini 文件路径实现隔离；应用运行时用默认构造（组织名/应用名在 main 中设置）。
class AppSettings : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int lastMode READ lastMode WRITE setLastMode NOTIFY lastModeChanged)
    Q_PROPERTY(int workMinutes READ workMinutes WRITE setWorkMinutes NOTIFY workMinutesChanged)
    Q_PROPERTY(int breakMinutes READ breakMinutes WRITE setBreakMinutes NOTIFY breakMinutesChanged)
    Q_PROPERTY(bool soundEnabled READ soundEnabled WRITE setSoundEnabled NOTIFY soundEnabledChanged)

public:
    static AppSettings* instance();
    explicit AppSettings(const QString& settingsFilePath = QString(), QObject* parent = nullptr);

    int lastMode() const;
    void setLastMode(int mode);
    int workMinutes() const;
    void setWorkMinutes(int minutes);
    int breakMinutes() const;
    void setBreakMinutes(int minutes);
    bool soundEnabled() const;
    void setSoundEnabled(bool enabled);

signals:
    void lastModeChanged();
    void workMinutesChanged();
    void breakMinutesChanged();
    void soundEnabledChanged();

private:
    QSettings* m_settings = nullptr;
};

#endif // APPSETTINGS_H
```

`src/services/AppSettings.cpp`：

```cpp
#include "AppSettings.h"

namespace {
const auto kLastModeKey = QStringLiteral("focus/lastMode");
const auto kWorkMinutesKey = QStringLiteral("focus/workMinutes");
const auto kBreakMinutesKey = QStringLiteral("focus/breakMinutes");
const auto kSoundEnabledKey = QStringLiteral("focus/soundEnabled");
}

AppSettings* AppSettings::instance()
{
    static AppSettings settings;
    return &settings;
}

AppSettings::AppSettings(const QString& settingsFilePath, QObject* parent)
    : QObject(parent)
    , m_settings(settingsFilePath.isEmpty()
                     ? new QSettings(this)
                     : new QSettings(settingsFilePath, QSettings::IniFormat, this))
{
}

int AppSettings::lastMode() const
{
    return m_settings->value(kLastModeKey, 0).toInt();
}

void AppSettings::setLastMode(int mode)
{
    if (lastMode() == mode) {
        return;
    }
    m_settings->setValue(kLastModeKey, mode);
    // 立即落盘：偏好丢失比多一次磁盘写入代价更高（应用可能被强退）。
    m_settings->sync();
    emit lastModeChanged();
}

int AppSettings::workMinutes() const
{
    return m_settings->value(kWorkMinutesKey, 25).toInt();
}

void AppSettings::setWorkMinutes(int minutes)
{
    if (workMinutes() == minutes) {
        return;
    }
    m_settings->setValue(kWorkMinutesKey, minutes);
    m_settings->sync();
    emit workMinutesChanged();
}

int AppSettings::breakMinutes() const
{
    return m_settings->value(kBreakMinutesKey, 5).toInt();
}

void AppSettings::setBreakMinutes(int minutes)
{
    if (breakMinutes() == minutes) {
        return;
    }
    m_settings->setValue(kBreakMinutesKey, minutes);
    m_settings->sync();
    emit breakMinutesChanged();
}

bool AppSettings::soundEnabled() const
{
    return m_settings->value(kSoundEnabledKey, true).toBool();
}

void AppSettings::setSoundEnabled(bool enabled)
{
    if (soundEnabled() == enabled) {
        return;
    }
    m_settings->setValue(kSoundEnabledKey, enabled);
    m_settings->sync();
    emit soundEnabledChanged();
}
```

`src/main.cpp`：include 区加 `#include "services/AppSettings.h"`；上下文属性区（`routineManager` 那行之后）加：

```cpp
    engine.rootContext()->setContextProperty(QStringLiteral("appSettings"), AppSettings::instance());
```

- [x] **Step 4: 运行测试确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: PASS（含两个新用例）。

- [x] **Step 5: 提交**

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp src/main.cpp CMakeLists.txt tests/ServiceTests.cpp
git commit -m "新增 AppSettings 偏好服务"
```

---

### Task 2: FocusView 接入偏好（注入、回写、恢复、直达函数）

**Files:**
- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: 无（`settings` 为鸭子类型注入，测试用 mock）
- Produces:
  - `property var settings: null`（MainWindow 注入 `appSettings`）
  - `function enterPomodoroWithTask(taskId, title)` — 切番茄待机态并预载任务
  - `selectWorkMinutes/selectBreakMinutes` 成功时回写 `settings.workMinutes/breakMinutes`
  - `startPomodoro` 成功时回写 `settings.lastMode = 1`
  - `Component.onCompleted` 从 `settings` 恢复时长

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml`：在 `focusTimer` mock 对象后新增 mock 设置对象：

```qml
    QtObject {
        id: appSettingsMock

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
    }
```

`FocusView { id: view ... }` 增加一行 `settings: appSettingsMock`。

`init()` 末尾（`view.selectBreakMinutes(5)` 之后）加入重置：

```qml
        appSettingsMock.lastMode = 0
        appSettingsMock.workMinutes = 25
        appSettingsMock.breakMinutes = 5
        appSettingsMock.soundEnabled = true
```

文件末尾新增测试：

```qml
    function test_selectPresetsWriteBackSettings() {
        view.toPomodoroTab(true)
        view.selectWorkMinutes(45)
        view.selectBreakMinutes(10)

        compare(appSettingsMock.workMinutes, 45)
        compare(appSettingsMock.breakMinutes, 10)
    }

    function test_startPomodoroWritesLastMode() {
        view.toPomodoroTab(true)
        view.startPomodoro()
        wait(20)

        compare(view.state, "pomoWork")
        compare(appSettingsMock.lastMode, 1)
    }

    function test_enterPomodoroWithTaskPreloadsIdle() {
        view.enterPomodoroWithTask(9, "直达任务")
        wait(20)

        compare(view.state, "pomoIdle")
        compare(view.pomodoroModeSelected, true)
        compare(view.pomoTaskId, 9)
        compare(view.pomoTaskTitle, "直达任务")
        compare(view.canStartPomodoro(), true)
    }

    function test_enterPomodoroWithTaskStopsActiveFreeSession() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true

        view.enterPomodoroWithTask(9, "直达任务")
        wait(20)

        // 复用 toPomodoroTab 的停止逻辑：进入直达前必须结束进行中的自由会话。
        compare(focusTimer.stopFocusCalls, 1)
        compare(view.state, "pomoIdle")
        compare(view.pomoTaskId, 9)
    }

    function test_restoreRememberedDurationsOnCreation() {
        var component = Qt.createComponent("../../qml/views/FocusView.qml")
        compare(component.status, Component.Ready)

        var restored = component.createObject(testCase, {
            timer: focusTimer,
            settings: rememberedSettingsMock
        })
        verify(restored)
        compare(restored.selectedWorkMinutes, 45)
        compare(restored.selectedBreakMinutes, 10)
        restored.destroy()
    }
```

并在 mock 区（`appSettingsMock` 之后）加恢复用的第二个 mock：

```qml
    QtObject {
        id: rememberedSettingsMock

        property int lastMode: 1
        property int workMinutes: 45
        property int breakMinutes: 10
        property bool soundEnabled: true
    }
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: 新用例 FAIL（`enterPomodoroWithTask` 未定义、settings 回写缺失）。

- [x] **Step 3: 改 FocusView.qml**

属性区（`property var timer: null` 之后）加：

```qml
    property var settings: null
```

`selectWorkMinutes`/`selectBreakMinutes` 改为（保持现有白名单，范围校验在第三部分放开）：

```qml
    function selectWorkMinutes(minutes) {
        if (minutes === 25 || minutes === 45 || minutes === 60) {
            root.selectedWorkMinutes = minutes
            if (root.settings) {
                root.settings.workMinutes = minutes
            }
        }
    }

    function selectBreakMinutes(minutes) {
        if (minutes === 5 || minutes === 10) {
            root.selectedBreakMinutes = minutes
            if (root.settings) {
                root.settings.breakMinutes = minutes
            }
        }
    }
```

`startPomodoro` 的成功分支（`root.errorText = ""` 处）改为：

```qml
        if (taskId > 0 && root.timer.startPomodoroWork(taskId, taskTitle, root.selectedWorkMinutes * 60)) {
            root.errorText = ""
            // 记住"实际启动过番茄"，供任务列表一键直达；只切标签页不算。
            if (root.settings) {
                root.settings.lastMode = 1
            }
        } else {
            root.errorText = "番茄专注启动失败"
        }
```

`toPomodoroTab` 函数之后新增：

```qml
    function enterPomodoroWithTask(taskId, title) {
        // 任务列表一键直达番茄待机：复用 toPomodoroTab 的停止/清理逻辑，
        // 再用显式传入的任务覆盖它从 timer 缓存的值（直达时 timer 里没有任务）。
        root.toPomodoroTab(true)
        if (taskId > 0) {
            root.pomoTaskId = taskId
        }
        if (title && title.length > 0) {
            root.pomoTaskTitle = title
        }
    }
```

根 Item 上加（`state: root.computeState()` 之后）：

```qml
    Component.onCompleted: {
        // 恢复上次记住的时长；无效值会被 select 函数的校验挡掉，回落默认。
        if (root.settings) {
            root.selectWorkMinutes(Number(root.settings.workMinutes))
            root.selectBreakMinutes(Number(root.settings.breakMinutes))
        }
    }
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS，连跑 2 次确认稳定。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "FocusView 接入偏好记忆与番茄直达入口"
```

---

### Task 3: MainWindow 集中启动决策 + 视图信号化

**Files:**
- Modify: `qml/MainWindow.qml`
- Modify: `qml/views/TodayTaskView.qml:448-454`（onStartFocusClicked）
- Modify: `qml/views/WeekPlanView.qml:463-469`（onStartFocusClicked）
- Create: `tests/qml/tst_focus_start_flow.qml`

**Interfaces:**
- Consumes: Task 2 的 `enterPomodoroWithTask(taskId, title)`、`settings` 注入；Task 1 的上下文属性 `appSettings`
- Produces:
  - MainWindow `property var appSettingsRef`、`function startFocusForTask(taskId, taskTitle)`
  - MainWindow 里 FocusView 实例 `id: focusView`、`objectName: "focusViewPage"`
  - 冲突分支（已有活动会话）：不启动、切到专注页（toast 文案在第二部分接入此分支）

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_focus_start_flow.qml`（stub 集合参照 `tst_mainwindow_ui_optimization.qml`，focusTimer 增加调用记录）：

```qml
import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: testCase
    name: "FocusStartFlow"
    when: windowShown
    width: 960
    height: 640

    QtObject {
        id: taskManager

        signal tasksChanged

        function getTodayTasks() { return []; }
        function getWeekTasks(weekStart) { return []; }
        function getMonthTasks(year, month) { return []; }
        function addTask(title, date, categoryId) {}
        function setTaskCompleted(id, completed) {}
        function deleteTask(id) { return true; }
    }

    QtObject {
        id: focusTimer

        property bool isRunning: false
        property bool hasActiveSession: false
        property int currentTaskId: -1
        property string currentTaskTitle: ""
        property int mode: 0
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
        property int startFocusCalls: 0
        property int startFocusTaskId: 0

        signal focusCompleted(int duration)
        signal phaseCompleted(int phase)

        function startFocus(id, title) {
            startFocusCalls += 1;
            startFocusTaskId = id;
            hasActiveSession = true;
            isRunning = true;
            return true;
        }
        function startPomodoroWork(id, title, workSeconds) { return true; }
        function startBreak(breakSeconds) { return true; }
        function pauseFocus() {}
        function resumeFocus() { return true; }
        function stopFocus() {
            hasActiveSession = false;
            isRunning = false;
            mode = 0;
            phase = 0;
            return true;
        }
    }

    QtObject {
        id: appSettings

        property int lastMode: 0
        property int workMinutes: 25
        property int breakMinutes: 5
        property bool soundEnabled: true
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 };
        }
        function makeComparison(displayText, trend) {
            return { hasData: true, displayText: displayText, trend: trend };
        }
        function getDayComparison(date) {
            return {
                taskCompletion: makeComparison("→ 0% vs 昨天", 0),
                sessionCount: makeComparison("→ 0% vs 昨天", 0),
                duration: makeComparison("→ 0% vs 昨天", 0)
            };
        }
        function getWeekStats() {
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 };
        }
        function getWeekComparison(weekStart) {
            return {
                effectiveDays: makeComparison("→ 0% vs 上周", 0),
                sessionCount: makeComparison("→ 0% vs 上周", 0),
                duration: makeComparison("→ 0% vs 上周", 0)
            };
        }
        function getCategoryStats(startDate, endDate) { return []; }
        function getMonthStats(year, month) {
            return { totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 };
        }
        function getMonthComparison(year, month) {
            return {
                effectiveDays: makeComparison("→ 0% vs 上月", 0),
                sessionCount: makeComparison("→ 0% vs 上月", 0),
                duration: makeComparison("→ 0% vs 上月", 0)
            };
        }
        function getMonthWeeklySummary(year, month) { return []; }
    }

    QtObject {
        id: categoryManager

        signal categoriesChanged

        function getCategories() { return []; }
        function getActiveCategories() { return []; }
    }

    QtObject {
        id: exportService
    }

    MainWindow {
        id: mainWindow

        width: testCase.width
        height: testCase.height
    }

    function init() {
        mainWindow.currentView = "today";
        mainWindow.pendingView = "today";
        mainWindow.queuedView = "";
        mainWindow.isSwitching = false;
        focusTimer.startFocusCalls = 0;
        focusTimer.startFocusTaskId = 0;
        focusTimer.hasActiveSession = false;
        focusTimer.isRunning = false;
        focusTimer.mode = 0;
        focusTimer.phase = 0;
        appSettings.lastMode = 0;
        var focusView = findChild(mainWindow, "focusViewPage");
        verify(focusView);
        focusView.toPomodoroTab(false);
        wait(20);
    }

    function test_freeModeStartsTimerImmediately() {
        appSettings.lastMode = 0;

        mainWindow.startFocusForTask(7, "自由任务");

        compare(focusTimer.startFocusCalls, 1);
        compare(focusTimer.startFocusTaskId, 7);
        compare(mainWindow.pendingView, "focus");
    }

    function test_pomodoroModeEntersIdleWithTask() {
        appSettings.lastMode = 1;

        mainWindow.startFocusForTask(9, "番茄任务");
        wait(20);

        compare(focusTimer.startFocusCalls, 0);
        var focusView = findChild(mainWindow, "focusViewPage");
        verify(focusView);
        compare(focusView.pomodoroModeSelected, true);
        compare(focusView.pomoTaskId, 9);
        compare(focusView.pomoTaskTitle, "番茄任务");
        compare(mainWindow.pendingView, "focus");
    }

    function test_conflictNavigatesWithoutStarting() {
        focusTimer.hasActiveSession = true;
        focusTimer.isRunning = true;

        mainWindow.startFocusForTask(11, "第二个任务");

        compare(focusTimer.startFocusCalls, 0);
        compare(mainWindow.pendingView, "focus");
    }

    function test_freeStartWritesLastMode() {
        appSettings.lastMode = 0;

        mainWindow.startFocusForTask(7, "自由任务");

        compare(appSettings.lastMode, 0);
    }
}
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（`startFocusForTask` 未定义、`focusViewPage` 找不到）。

- [x] **Step 3: 改 MainWindow.qml 与两个视图**

`qml/MainWindow.qml` 属性区（`countdownServiceRef` 之后）加：

```qml
    property var appSettingsRef: typeof appSettings === "undefined" ? null : appSettings
```

`viewIndex` 函数之后新增：

```qml
    function startFocusForTask(taskId, taskTitle) {
        // 冲突：已有活动会话（含休息段）时不启动新专注，带用户去专注页现场决策。
        if (focusTimer.hasActiveSession || focusTimer.phase !== 0) {
            root.switchToView("focus");
            return;
        }

        // 记住上次模式：番茄 → 进待机带任务不偷跑；自由 → 立即计时（与旧行为一致）。
        if (root.appSettingsRef && root.appSettingsRef.lastMode === 1) {
            focusView.enterPomodoroWithTask(taskId, taskTitle);
            root.switchToView("focus");
            return;
        }

        if (focusTimer.startFocus(taskId, taskTitle)) {
            if (root.appSettingsRef) {
                root.appSettingsRef.lastMode = 0;
            }
            root.switchToView("focus");
        }
    }
```

FocusView 实例改为：

```qml
                FocusView {
                    id: focusView
                    objectName: "focusViewPage"
                    timer: focusTimer
                    settings: root.appSettingsRef

                    onFocusEnded: {
                        root.switchToView("today");
                    }
                }
```

TodayTaskView 与 WeekPlanView 的实例处，`onStartFocus` 改为：

```qml
                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }
```

（MonthGoalView 的 `onStartFocus` 同样改为调 `startFocusForTask`，保持一致。）

`qml/views/TodayTaskView.qml` 的 `onStartFocusClicked` 改为（不再直接调 focusTimer，也不再在此处设置错误文案——启动决策移交 MainWindow）：

```qml
                            onStartFocusClicked: function (id, title) {
                                root.startFocus(id, title);
                            }
```

`qml/views/WeekPlanView.qml` 的 `onStartFocusClicked` 同样改为：

```qml
                                    onStartFocusClicked: function(id, title) {
                                        root.startFocus(id, title)
                                    }
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run:
```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/MainWindow.qml qml/views/TodayTaskView.qml qml/views/WeekPlanView.qml
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"
```
Expected: lint 无输出；全部 PASS。

- [x] **Step 5: 回归检查（受影响的既有测试文件）**

Run:
```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml 2>/dev/null | grep -E "FAIL|Totals"
```
Expected: 全绿。若 `tst_ui_optimization.qml` 中有测试依赖「今日页点开始专注会调 focusTimer.startFocus」，按新行为改断言（改为验证视图发出 `startFocus` 信号——用 `SignalSpy { target: view; signalName: "startFocus" }`）。

- [x] **Step 6: 全量构建 + 提交**

```bash
cmake --build build && ctest --test-dir build --output-on-failure
git add qml/MainWindow.qml qml/views/TodayTaskView.qml qml/views/WeekPlanView.qml tests/qml/tst_focus_start_flow.qml tests/qml/tst_ui_optimization.qml
git commit -m "任务列表开始专注按上次模式一键直达"
```

（QML 整套若只有既有粒子偶发失败，重跑一次确认；仍失败则单文件跑本计划涉及的四个测试文件核实全绿后照常提交。）
