# 专注 UX 改进第二部分：全局运行状态 + 轻提示条 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 侧栏「专注计时」条目实时显示运行状态与时间；窗口标题同步；新增全局 Toast；短会话丢弃与启动冲突给出明确提示。

**Architecture:** `FocusTimer` 新增 `sessionDiscarded(int)` 信号（只加信号不改流程）；Sidebar/MainWindow 通过参数透传的纯函数把 timer 状态格式化为文本（保证绑定响应 `tick`）；Toast 是 MainWindow 顶层单实例组件，视图不直接引用。

**Tech Stack:** Qt 6.9 / C++17 / Qt Quick(QML) / Qt Test / CMake。

**对应规格:** `docs/superpowers/specs/2026-07-05-focus-ux-improvements-design.md` 的「②」「③④（toast 部分）」。

**前置依赖:** 第一部分已合入（依赖 MainWindow 的 `startFocusForTask` 冲突分支、`tests/qml/tst_focus_start_flow.qml`）。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；每个任务改完跑构建与相关测试再提交。
- 配置：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`；构建：`cmake --build build`；C++ 测试：`ctest --test-dir build -R PomodoroTodoTests --output-on-failure`；单文件 QML：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<file>.qml`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`。
- 分支 `focus-ux-improvements`（第一部分创建，直接继续）。
- **QML 测试纪律**：绝不断言 `something.visible === true`；断言驱动它的源头属性。
- 时间格式规则（侧栏与标题共用）：番茄模式 `mm:ss`（remainingSeconds），自由模式 `hh:mm:ss`（elapsedSeconds）；运行中前缀 `● `，暂停前缀 `⏸ `。
- 文案用裸中文（不加 `qsTr()`）。

---

### Task 1: FocusTimer 新增 sessionDiscarded 信号（C++）

**Files:**
- Modify: `src/services/FocusTimer.h`（signals 区加一行）
- Modify: `src/services/FocusTimer.cpp`（丢弃分支加一行 emit）
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces: `void sessionDiscarded(int duration)` — 会话因不足 3 分钟被删除时发出，参数为实际秒数。

- [x] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` 的 `private slots:` 区加：

```cpp
    void shortSessionEmitsSessionDiscarded();
    void validSessionDoesNotEmitSessionDiscarded();
```

实现区加（`insertTaskRow` 为文件既有辅助函数，与番茄状态机测试同用法；`FocusTimer` 已通过 `#define private public` 可推进内部计数）：

```cpp
void ServiceTests::shortSessionEmitsSessionDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("短会话任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy discardSpy(timer, &FocusTimer::sessionDiscarded);

    QVERIFY(timer->startFocus(taskId, QStringLiteral("短会话任务")));
    timer->m_elapsedSeconds = 60; // 1 分钟 < 3 分钟门槛
    QVERIFY(timer->stopFocus());

    QCOMPARE(discardSpy.count(), 1);
    QCOMPARE(discardSpy.takeFirst().at(0).toInt(), 60);
}

void ServiceTests::validSessionDoesNotEmitSessionDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("有效会话任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy discardSpy(timer, &FocusTimer::sessionDiscarded);

    QVERIFY(timer->startFocus(taskId, QStringLiteral("有效会话任务")));
    timer->m_elapsedSeconds = 300; // 5 分钟 ≥ 3 分钟门槛
    QVERIFY(timer->stopFocus());

    QCOMPARE(discardSpy.count(), 0);
}
```

- [x] **Step 2: 运行测试确认编译失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误（`sessionDiscarded` 不是 `FocusTimer` 成员）。

- [x] **Step 3: 写实现**

`src/services/FocusTimer.h` 的 `signals:` 区（`phaseCompleted` 之后）加：

```cpp
    void sessionDiscarded(int duration);
```

`src/services/FocusTimer.cpp` 的 `completeFocusSession()` 丢弃分支，在 `resetSession();` 与 `emit focusCompleted(duration);` 之间加：

```cpp
        // 静默丢弃会让用户误以为已记录；界面靠这个信号弹"未计入"提示。
        emit sessionDiscarded(duration);
```

- [x] **Step 4: 运行测试确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: PASS。

- [x] **Step 5: 提交**

```bash
git add src/services/FocusTimer.h src/services/FocusTimer.cpp tests/ServiceTests.cpp
git commit -m "短会话丢弃时发出 sessionDiscarded 信号"
```

---

### Task 2: 侧栏专注状态区

**Files:**
- Modify: `qml/components/Sidebar.qml`
- Modify: `qml/MainWindow.qml`（Sidebar 实例传 `focusTimerRef`）
- Test: `tests/qml/tst_sidebar_ui_optimization.qml`

**Interfaces:**
- Consumes: 全局 `focusTimer` 的属性（hasActiveSession/phase/mode/isRunning/remainingSeconds/elapsedSeconds，NOTIFY 已齐）
- Produces:
  - Sidebar `property var focusTimerRef: null`
  - Sidebar `function focusStatusFor(hasActiveSession, phase, mode, isRunning, remainingSeconds, elapsedSeconds)` → 状态文本（空闲返回 ""）
  - SidebarItem 新增 `property string statusText`；状态 Text 的 objectName 为 `"sidebarStatus-" + marker`（专注条目即 `sidebarStatus-专`）

- [x] **Step 1: 写失败测试**

`tests/qml/tst_sidebar_ui_optimization.qml`：在 Sidebar 实例处注入 mock（该文件已有 Sidebar 实例，加属性即可；若无 mock timer 则在 TestCase 里加）：

```qml
    QtObject {
        id: focusTimerMock

        property bool isRunning: false
        property bool hasActiveSession: false
        property int mode: 0
        property int phase: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
    }
```

Sidebar 实例加一行 `focusTimerRef: focusTimerMock`。新增测试：

```qml
    function test_focusStatusShowsPomodoroCountdown() {
        focusTimerMock.hasActiveSession = true
        focusTimerMock.isRunning = true
        focusTimerMock.mode = 1
        focusTimerMock.phase = 1
        focusTimerMock.remainingSeconds = 932
        wait(20)

        const status = findChild(sidebar, "sidebarStatus-专")
        verify(status)
        compare(status.text, "● 15:32")
    }

    function test_focusStatusShowsFreeElapsedAndPause() {
        focusTimerMock.hasActiveSession = true
        focusTimerMock.isRunning = false
        focusTimerMock.mode = 0
        focusTimerMock.phase = 0
        focusTimerMock.elapsedSeconds = 1934
        wait(20)

        const status = findChild(sidebar, "sidebarStatus-专")
        verify(status)
        compare(status.text, "⏸ 00:32:14")
    }

    function test_focusStatusEmptyWhenIdle() {
        focusTimerMock.hasActiveSession = false
        focusTimerMock.isRunning = false
        focusTimerMock.mode = 0
        focusTimerMock.phase = 0
        wait(20)

        const status = findChild(sidebar, "sidebarStatus-专")
        verify(status)
        compare(status.text, "")
    }
```

（`sidebar` 为该文件中 Sidebar 实例的 id，以现有文件为准；若实例 id 不同，测试中相应替换。）

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: 新用例 FAIL（`sidebarStatus-专` 不存在）。

- [x] **Step 3: 改 Sidebar.qml 与 MainWindow.qml**

`qml/components/Sidebar.qml` 根属性区（`exportServiceRef` 之后）加：

```qml
    property var focusTimerRef: null
```

根函数区（信号声明之后）加：

```qml
    function formatMinuteTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var minutes = Math.floor(safe / 60)
        var secs = safe % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (secs < 10 ? "0" : "") + secs
    }

    function formatClockTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function focusStatusFor(hasActiveSession, phase, mode, isRunning, remainingSeconds, elapsedSeconds) {
        // 参数全部显式传入而不是在函数里读 focusTimerRef：这样绑定表达式
        // 依赖这些具体属性，remainingSeconds/elapsedSeconds 每秒 NOTIFY 才会驱动刷新。
        var active = hasActiveSession || phase !== 0
        if (!active) {
            return ""
        }
        var timeText = mode === 1 ? root.formatMinuteTime(remainingSeconds) : root.formatClockTime(elapsedSeconds)
        return (isRunning ? "● " : "⏸ ") + timeText
    }
```

`SidebarItem` 组件加属性（`isActive` 之后）：

```qml
        property string statusText: ""
```

`SidebarItem` 内 RowLayout 的标题 Text 之后加状态 Text：

```qml
            Text {
                objectName: "sidebarStatus-" + item.marker
                visible: item.statusText.length > 0
                text: item.statusText
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
                color: Theme.accent
            }
```

「专注计时」的 SidebarItem 实例加：

```qml
        SidebarItem {
            text: "专注计时"
            marker: "专"
            isActive: root.currentView === "focus"
            statusText: root.focusTimerRef
                        ? root.focusStatusFor(root.focusTimerRef.hasActiveSession,
                                              root.focusTimerRef.phase,
                                              root.focusTimerRef.mode,
                                              root.focusTimerRef.isRunning,
                                              root.focusTimerRef.remainingSeconds,
                                              root.focusTimerRef.elapsedSeconds)
                        : ""
            onClicked: root.itemClicked("focus")
        }
```

`qml/MainWindow.qml` 的 Sidebar 实例加一行：

```qml
            focusTimerRef: focusTimer
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/Sidebar.qml qml/MainWindow.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS。

- [x] **Step 5: 提交**

```bash
git add qml/components/Sidebar.qml qml/MainWindow.qml tests/qml/tst_sidebar_ui_optimization.qml
git commit -m "侧栏专注条目常驻显示运行状态与时间"
```

---

### Task 3: 窗口标题同步

**Files:**
- Modify: `qml/MainWindow.qml`（windowTitleText 计算属性）
- Modify: `qml/main.qml`（title 绑定）
- Test: `tests/qml/tst_focus_start_flow.qml`

**Interfaces:**
- Consumes: 全局 `focusTimer`
- Produces: MainWindow `readonly property string windowTitleText`；main.qml 的 MainWindow 实例 `id: mainContent`，窗口 `title: mainContent.windowTitleText`

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_start_flow.qml` 新增：

```qml
    function test_windowTitleReflectsTimerState() {
        compare(mainWindow.windowTitleText, "番茄Todo");

        focusTimer.hasActiveSession = true;
        focusTimer.isRunning = true;
        focusTimer.mode = 1;
        focusTimer.phase = 1;
        focusTimer.remainingSeconds = 932;
        compare(mainWindow.windowTitleText, "15:32 · 番茄Todo");

        focusTimer.isRunning = false;
        compare(mainWindow.windowTitleText, "⏸ 15:32 · 番茄Todo");

        focusTimer.mode = 0;
        focusTimer.phase = 0;
        focusTimer.elapsedSeconds = 1934;
        focusTimer.isRunning = true;
        compare(mainWindow.windowTitleText, "00:32:14 · 番茄Todo");
    }
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（`windowTitleText` 未定义）。

- [x] **Step 3: 写实现**

`qml/MainWindow.qml` 属性区加（`appSettingsRef` 之后）：

```qml
    property var focusTimerRef: typeof focusTimer === "undefined" ? null : focusTimer
    readonly property string windowTitleText: root.focusTimerRef
        ? root.windowTitleFor(root.focusTimerRef.hasActiveSession,
                              root.focusTimerRef.phase,
                              root.focusTimerRef.mode,
                              root.focusTimerRef.isRunning,
                              root.focusTimerRef.remainingSeconds,
                              root.focusTimerRef.elapsedSeconds)
        : "番茄Todo"
```

函数区加（时间格式与侧栏同规则；参数显式传入保证绑定随 tick 刷新）：

```qml
    function formatMinuteTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var minutes = Math.floor(safe / 60)
        var secs = safe % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (secs < 10 ? "0" : "") + secs
    }

    function formatClockTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function windowTitleFor(hasActiveSession, phase, mode, isRunning, remainingSeconds, elapsedSeconds) {
        var active = hasActiveSession || phase !== 0
        if (!active) {
            return "番茄Todo"
        }
        var timeText = mode === 1 ? root.formatMinuteTime(remainingSeconds) : root.formatClockTime(elapsedSeconds)
        return (isRunning ? "" : "⏸ ") + timeText + " · 番茄Todo"
    }
```

`qml/main.qml`：MainWindow 实例加 `id: mainContent`，ApplicationWindow 的 `title: "番茄Todo"` 改为：

```qml
    title: mainContent.windowTitleText
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/MainWindow.qml qml/main.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS。

- [x] **Step 5: 提交**

```bash
git add qml/MainWindow.qml qml/main.qml tests/qml/tst_focus_start_flow.qml
git commit -m "窗口标题同步专注计时状态"
```

---

### Task 4: Toast 组件 + 丢弃/冲突提示接线

**Files:**
- Create: `qml/components/Toast.qml`
- Modify: `resources/qml.qrc`（注册 Toast.qml）
- Modify: `qml/MainWindow.qml`（实例化 + showToast + 两处接线）
- Test: `tests/qml/tst_focus_start_flow.qml`

**Interfaces:**
- Consumes: Task 1 的 `sessionDiscarded(int)`；第一部分的 `startFocusForTask` 冲突分支
- Produces:
  - `Toast` 组件：`function show(message)`、`property bool shown`、`property int displayDurationMs: 3000`、内部文本 objectName `"toastText"`、根 objectName `"globalToast"`
  - MainWindow `function showToast(message)`
  - 文案：丢弃 → `"本次专注不足 3 分钟，未计入记录"`；冲突 → `"已有专注进行中"`

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_start_flow.qml` 的 focusTimer mock 加一行信号声明（属性区之后）：

```qml
        signal sessionDiscarded(int duration)
```

新增测试：

```qml
    function test_toastShowsAndAutoHides() {
        var toast = findChild(mainWindow, "globalToast");
        verify(toast);
        toast.displayDurationMs = 60;

        mainWindow.showToast("测试提示");
        compare(toast.shown, true);
        var label = findChild(mainWindow, "toastText");
        verify(label);
        compare(label.text, "测试提示");

        tryCompare(toast, "shown", false, 2000);
        toast.displayDurationMs = 3000;
    }

    function test_sessionDiscardedShowsToast() {
        var toast = findChild(mainWindow, "globalToast");
        verify(toast);

        focusTimer.sessionDiscarded(60);
        wait(20);

        compare(toast.shown, true);
        var label = findChild(mainWindow, "toastText");
        compare(label.text, "本次专注不足 3 分钟，未计入记录");
    }

    function test_conflictShowsToast() {
        focusTimer.hasActiveSession = true;
        focusTimer.isRunning = true;

        mainWindow.startFocusForTask(11, "第二个任务");
        wait(20);

        var toast = findChild(mainWindow, "globalToast");
        verify(toast);
        compare(toast.shown, true);
        var label = findChild(mainWindow, "toastText");
        compare(label.text, "已有专注进行中");
    }
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（`globalToast` 不存在、`showToast` 未定义）。

- [x] **Step 3: 写实现**

新建 `qml/components/Toast.qml`：

```qml
import QtQuick
import ".."

// 全局轻提示条：底部居中浮现，displayDurationMs 后自动退场。
// 连续 show 会重置计时并替换文本（不排队），因为提示都是低优先级的瞬时信息。
Rectangle {
    id: root

    objectName: "globalToast"

    property int displayDurationMs: 3000
    property bool shown: false

    function show(message) {
        label.text = message
        root.shown = true
        hideTimer.restart()
    }

    implicitWidth: label.implicitWidth + Theme.space24 * 2
    implicitHeight: 40
    radius: Theme.radiusLg
    color: Theme.inkStrong
    opacity: root.shown ? 0.92 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Text {
        id: label

        objectName: "toastText"
        anchors.centerIn: parent
        color: Theme.surface
        font.pixelSize: Theme.fontMd
    }

    Timer {
        id: hideTimer

        interval: root.displayDurationMs
        onTriggered: root.shown = false
    }
}
```

`resources/qml.qrc` 加一行（components 区内）：

```xml
        <file alias="qml/components/Toast.qml">../qml/components/Toast.qml</file>
```

`qml/MainWindow.qml`：

函数区加：

```qml
    function showToast(message) {
        globalToast.show(message);
    }
```

`startFocusForTask` 的冲突分支改为：

```qml
        if (focusTimer.hasActiveSession || focusTimer.phase !== 0) {
            root.showToast("已有专注进行中");
            root.switchToView("focus");
            return;
        }
```

根 Item 末尾（各 Dialog 之前）加实例与接线：

```qml
    Toast {
        id: globalToast

        z: 100
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space32
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true

        function onSessionDiscarded(duration) {
            root.showToast("本次专注不足 3 分钟，未计入记录");
        }
    }
```

（MainWindow 需 `import "."` 已有；Toast 在 components 目录，确认已有 `import "components"`。）

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/Toast.qml qml/MainWindow.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS，连跑 2 次稳定。

- [x] **Step 5: 全量构建 + 提交**

```bash
cmake --build build && ctest --test-dir build --output-on-failure
git add qml/components/Toast.qml resources/qml.qrc qml/MainWindow.qml tests/qml/tst_focus_start_flow.qml
git commit -m "新增全局轻提示条并接入丢弃与冲突提示"
```
