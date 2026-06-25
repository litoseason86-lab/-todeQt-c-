# 双模式专注（自由 + 番茄）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留现有自由正计时的基础上，给 FocusTimer/FocusView 加番茄模式（专注倒计时 → 到点视觉提醒+窗口置前 → 手动转休息 → 提醒 → 回到专注），固定预设时长。

**Architecture:** 扩展 `FocusTimer` 单例加「模式/阶段/目标」状态机：复用同一个 `m_elapsedSeconds` 计数器，番茄模式下 tick 到达 `targetSeconds` 即结算并发 `phaseCompleted`。专注段照写 `focus_sessions`（复用现有 3/5 分钟规则与自动完成），休息段不写。FocusView 顶部模式切换，番茄态用 QML `states` 建模。无数据库迁移。

**Tech Stack:** Qt 6.9 / C++17 / Qt Quick(QML) / SQLite / CMake / Qt Test。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；改完跑构建与测试再报告。
- 配置：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`；构建：`cmake --build build`；全部测试：`ctest --test-dir build --output-on-failure`；C++：`-R PomodoroTodoTests`；QML：`-R PomodoroTodoQmlTests`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`。
- 当前分支 `dual-mode-pomodoro`（已检出，勿切换）。
- **QML 规范（按 qt-qml）**：模式/预设用 Qt Quick Controls（`ButtonGroup`+`Button` 互斥），不裸 `MouseArea` 自造；FocusView 多形态用 QML `states`；倒计时声明式绑 `focusTimer.remainingSeconds`，1Hz 格式化不驱动逐帧动画；高亮动画用 `Animator` 类；窗口置前用单个 `Connections`；**文案用裸中文**（随项目、不加 `qsTr()`）；沿用项目 plain `import QtQuick.Controls`；**本期不做 a11y**。
- 时长常量：专注预设 25/45/60 分，休息 5/10 分（默认 25/5）。mode：0=自由、1=番茄；phase：0=无、1=专注、2=休息。

---

## Task 1：FocusTimer 番茄状态机（C++）

**Files:**
- Modify: `src/services/FocusTimer.h`
- Modify: `src/services/FocusTimer.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces（自由模式 API 全部保留不变）：
  - 属性：`int mode`、`int phase`、`int targetSeconds`、`int remainingSeconds`、`int currentTaskId`
  - 方法：`Q_INVOKABLE bool startPomodoroWork(int taskId, const QString& taskTitle, int workSeconds)`、`Q_INVOKABLE bool startBreak(int breakSeconds)`
  - 信号：`phaseCompleted(int phase)`（番茄阶段倒计时归零时发出，phase=1 专注 / 2 休息）

- [ ] **Step 1：写失败测试**

在 `tests/ServiceTests.cpp` 的 `private slots:` 区声明：
```cpp
    void pomodoroWorkCompletionSavesSessionAndAutoCompletesTask();
    void pomodoroBreakWritesNoSessionAndCompletes();
    void pomodoroWorkStoppedUnderMinimumIsDiscarded();
    void freeFocusStillCountsUpUnchanged();
```
实现区加入（`FocusTimer` 已通过 `#define private public` 可直接推进内部计数）：
```cpp
void ServiceTests::pomodoroWorkCompletionSavesSessionAndAutoCompletesTask()
{
    const int taskId = insertTaskRow(QStringLiteral("番茄任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy phaseSpy(timer, &FocusTimer::phaseCompleted);

    // 25 分钟专注；直接把已用秒数推到目标，模拟倒计时归零。
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("番茄任务"), 25 * 60));
    QCOMPARE(timer->mode(), 1);
    QCOMPARE(timer->phase(), 1);
    QCOMPARE(timer->targetSeconds(), 25 * 60);

    timer->m_elapsedSeconds = 25 * 60 - 1;
    emit timer->m_timer.timeout(); // 触发最后一拍 → 归零 → 结算

    QCOMPARE(phaseSpy.count(), 1);
    QCOMPARE(phaseSpy.takeFirst().at(0).toInt(), 1); // 专注阶段完成
    QVERIFY(!timer->hasActiveSession());              // 已结算复位

    // 会话已写库
    QSqlQuery q(DatabaseManager::instance()->database());
    QVERIFY(q.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE duration = %1").arg(25 * 60)));
    QVERIFY(q.next());
    QCOMPARE(q.value(0).toInt(), 1);
    // 25 分钟 ≥ 5 分钟 → 任务自动完成
    QVERIFY(TaskManager::instance()->getTasksByDate(QDate::currentDate()).first().toMap()
                .value(QStringLiteral("completed")).toBool());
}

void ServiceTests::pomodoroBreakWritesNoSessionAndCompletes()
{
    FocusTimer* timer = FocusTimer::instance();
    QSignalSpy phaseSpy(timer, &FocusTimer::phaseCompleted);

    QVERIFY(timer->startBreak(5 * 60));
    QCOMPARE(timer->phase(), 2);
    QVERIFY(!timer->hasActiveSession()); // 休息段不建会话

    timer->m_elapsedSeconds = 5 * 60 - 1;
    emit timer->m_timer.timeout();

    QCOMPARE(phaseSpy.count(), 1);
    QCOMPARE(phaseSpy.takeFirst().at(0).toInt(), 2); // 休息阶段完成
    QSqlQuery q(DatabaseManager::instance()->database());
    QVERIFY(q.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")));
    QVERIFY(q.next());
    QCOMPARE(q.value(0).toInt(), 0); // 休息全程不写任何会话
}

void ServiceTests::pomodoroWorkStoppedUnderMinimumIsDiscarded()
{
    const int taskId = insertTaskRow(QStringLiteral("短番茄"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startPomodoroWork(taskId, QStringLiteral("短番茄"), 25 * 60));

    timer->m_elapsedSeconds = 60; // 1 分钟，< 3 分钟门槛
    QVERIFY(timer->stopFocus());

    QSqlQuery q(DatabaseManager::instance()->database());
    QVERIFY(q.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions")));
    QVERIFY(q.next());
    QCOMPARE(q.value(0).toInt(), 0); // 无效会话被丢弃
}

void ServiceTests::freeFocusStillCountsUpUnchanged()
{
    const int taskId = insertTaskRow(QStringLiteral("自由任务"), QDate::currentDate());
    FocusTimer* timer = FocusTimer::instance();
    QVERIFY(timer->startFocus(taskId, QStringLiteral("自由任务")));
    QCOMPARE(timer->mode(), 0);          // 自由模式
    QCOMPARE(timer->targetSeconds(), 0); // 无目标
    timer->m_elapsedSeconds = 10 * 60;   // 正计时累计
    emit timer->m_timer.timeout();
    QCOMPARE(timer->elapsedSeconds(), 10 * 60 + 1); // 继续往上数、不会自动结算
    QVERIFY(timer->hasActiveSession());
    QVERIFY(timer->stopFocus());
}
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: 四个新用例 FAIL（`mode()`/`startPomodoroWork` 等未定义，编译失败）。

- [ ] **Step 3：改 FocusTimer.h**

把属性区（`Q_PROPERTY` 那几行后）补全为：
```cpp
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY tick)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY runningStateChanged)
    Q_PROPERTY(bool hasActiveSession READ hasActiveSession NOTIFY currentTaskChanged)
    Q_PROPERTY(QString currentTaskTitle READ currentTaskTitle NOTIFY currentTaskChanged)
    Q_PROPERTY(int currentTaskId READ currentTaskId NOTIFY currentTaskChanged)
    Q_PROPERTY(int mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(int phase READ phase NOTIFY phaseChanged)
    Q_PROPERTY(int targetSeconds READ targetSeconds NOTIFY phaseChanged)
    Q_PROPERTY(int remainingSeconds READ remainingSeconds NOTIFY tick)
```
`public:` 方法区在 `stopFocus` 之后加：
```cpp
    // 番茄模式：专注段绑定任务、建立会话；休息段无任务、不建会话。
    Q_INVOKABLE bool startPomodoroWork(int taskId, const QString& taskTitle, int workSeconds);
    Q_INVOKABLE bool startBreak(int breakSeconds);
```
getter 区（`currentTaskTitle()` 后）加：
```cpp
    int currentTaskId() const;
    int mode() const;
    int phase() const;
    int targetSeconds() const;
    int remainingSeconds() const;
```
`signals:` 区加：
```cpp
    void modeChanged();
    void phaseChanged();
    void phaseCompleted(int phase);
```
`private:` 成员区加（在 `int m_sessionId = -1;` 后）：
```cpp
    // 番茄状态：模式/阶段/目标秒数。自由模式 target 为 0、不触发归零结算。
    int m_mode = 0;          // 0=自由 1=番茄
    int m_phase = 0;         // 0=无 1=专注 2=休息
    int m_targetSeconds = 0;
    // 番茄专注段倒计时归零时的结算与广播；休息段不写库。
    void completePomodoroPhase();
```

- [ ] **Step 4：改 FocusTimer.cpp**

构造函数里的 tick lambda 改为（加番茄归零判断）：
```cpp
    m_timer.setInterval(1000);
    connect(&m_timer, &QTimer::timeout, this, [this]() {
        ++m_elapsedSeconds;
        emit tick();
        // 番茄模式：到达目标秒数即结算当前阶段并提醒。
        if (m_mode == 1 && m_targetSeconds > 0 && m_elapsedSeconds >= m_targetSeconds) {
            completePomodoroPhase();
        }
    });
```
`startFocus(...)` 末尾设置自由模式状态——在 `m_isRunning = true;` 之后、`m_timer.start();` 之前加：
```cpp
    m_mode = 0;
    m_phase = 0;
    m_targetSeconds = 0;
```
并在 `startFocus` 的 `return true;` 前补发：`emit modeChanged(); emit phaseChanged();`

`stopFocus()` 开头加休息段分支（在 `if (m_sessionId == -1)` 之前）：
```cpp
    // 休息段没有会话记录，停止即直接复位丢弃。
    if (m_phase == 2) {
        resetSession();
        emit modeChanged();
        emit phaseChanged();
        emit runningStateChanged();
        emit currentTaskChanged();
        emit tick();
        return true;
    }
```
`resetSession()` 末尾补番茄状态复位：
```cpp
    m_mode = 0;
    m_phase = 0;
    m_targetSeconds = 0;
```
getter 实现区（`currentTaskTitle()` 后）加：
```cpp
int FocusTimer::currentTaskId() const { return m_currentTaskId; }
int FocusTimer::mode() const { return m_mode; }
int FocusTimer::phase() const { return m_phase; }
int FocusTimer::targetSeconds() const { return m_targetSeconds; }
int FocusTimer::remainingSeconds() const
{
    // 仅番茄模式有意义；自由模式返回 0。
    if (m_mode != 1 || m_targetSeconds <= 0) {
        return 0;
    }
    const int remaining = m_targetSeconds - m_elapsedSeconds;
    return remaining > 0 ? remaining : 0;
}
```
文件末尾加新方法：
```cpp
bool FocusTimer::startPomodoroWork(int taskId, const QString& taskTitle, int workSeconds)
{
    if (m_sessionId != -1 || m_isRunning) {
        qWarning() << "Failed to start pomodoro work: timer already active"
                   << "sessionId=" << m_sessionId;
        return false;
    }
    if (taskId <= 0 || workSeconds <= 0) {
        qWarning() << "Failed to start pomodoro work: invalid task or duration"
                   << "taskId=" << taskId << "workSeconds=" << workSeconds;
        return false;
    }
    const QString normalizedTitle = taskTitle.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to start pomodoro work: empty title";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to start pomodoro work: database is not open";
        return false;
    }

    const QDateTime now = QDateTime::currentDateTime();
    QSqlQuery query(db);
    query.prepare(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time) VALUES (:taskId, :startTime)"));
    query.bindValue(QStringLiteral(":taskId"), taskId);
    query.bindValue(QStringLiteral(":startTime"), now.toString(Qt::ISODate));
    if (!query.exec()) {
        qWarning() << "Failed to create pomodoro session:" << query.lastError().text();
        return false;
    }

    m_sessionId = query.lastInsertId().toInt();
    m_currentTaskId = taskId;
    m_currentTaskTitle = normalizedTitle;
    m_startTime = now;
    m_elapsedSeconds = 0;
    m_isRunning = true;
    m_mode = 1;
    m_phase = 1;
    m_targetSeconds = workSeconds;
    m_timer.start();

    emit modeChanged();
    emit phaseChanged();
    emit runningStateChanged();
    emit currentTaskChanged();
    emit tick();
    return true;
}

bool FocusTimer::startBreak(int breakSeconds)
{
    if (m_sessionId != -1 || m_isRunning) {
        qWarning() << "Failed to start break: timer already active";
        return false;
    }
    if (breakSeconds <= 0) {
        qWarning() << "Failed to start break: invalid duration" << breakSeconds;
        return false;
    }

    // 休息段不绑定任务、不建立 focus_sessions 行（不计入统计）。
    m_sessionId = -1;
    m_currentTaskId = -1;
    m_currentTaskTitle.clear();
    m_startTime = QDateTime::currentDateTime();
    m_elapsedSeconds = 0;
    m_isRunning = true;
    m_mode = 1;
    m_phase = 2;
    m_targetSeconds = breakSeconds;
    m_timer.start();

    emit modeChanged();
    emit phaseChanged();
    emit runningStateChanged();
    emit currentTaskChanged();
    emit tick();
    return true;
}

void FocusTimer::completePomodoroPhase()
{
    m_timer.stop();
    m_isRunning = false;
    const int finishedPhase = m_phase;
    const int duration = m_elapsedSeconds;
    const int taskId = m_currentTaskId;

    if (finishedPhase == 1) {
        // 专注段到点：写库 + 达标自动完成任务（25/45/60 分必然 ≥ 5 分钟）。
        // 自然到点属正常完成，写库失败仅告警，不回滚计时（已归零）。
        if (!saveFocusSession(duration)) {
            qWarning() << "Failed to save completed pomodoro session" << "duration=" << duration;
        } else if (duration >= FocusSessionRules::kAutoCompleteTaskDurationSeconds) {
            if (!TaskManager::instance()->setTaskCompleted(taskId, true)) {
                qWarning() << "Failed to auto-complete task after pomodoro" << "taskId=" << taskId;
            }
        }
    }
    // 休息段无会话，无需结算。

    resetSession();
    emit phaseCompleted(finishedPhase);
    emit modeChanged();
    emit phaseChanged();
    emit runningStateChanged();
    emit currentTaskChanged();
    emit tick();
}
```

- [ ] **Step 5：运行测试，确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: 全部 PASS（四个新用例 + 既有用例不回归）。

- [ ] **Step 6：提交**

```bash
git add src/services/FocusTimer.h src/services/FocusTimer.cpp tests/ServiceTests.cpp
git commit -m "FocusTimer 新增番茄模式状态机与到点结算"
```

---

## Task 2：FocusView 双模式 UI（QML）

**Files:**
- Modify: `qml/views/FocusView.qml`（整文件重写，保留自由模式行为）
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: Task 1 的 `focusTimer`（`mode/phase/targetSeconds/remainingSeconds/currentTaskId/startPomodoroWork/startBreak/phaseCompleted` + 既有 API）。

- [ ] **Step 1：写失败测试**

`tests/qml/tst_focus_view.qml`：
```qml
import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "FocusViewDualMode"
    when: windowShown
    width: 800
    height: 600

    property int lastWorkSeconds: 0

    QtObject {
        id: fakeFocusTimer
        property int elapsedSeconds: 0
        property bool isRunning: false
        property bool hasActiveSession: false
        property string currentTaskTitle: "操作系统"
        property int currentTaskId: 7
        property int mode: 0
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        signal tick()
        signal runningStateChanged()
        signal currentTaskChanged()
        signal focusCompleted(int duration)
        signal modeChanged()
        signal phaseChanged()
        signal phaseCompleted(int phase)
        function startFocus(id, title) { return true }
        function pauseFocus() {}
        function resumeFocus() { return true }
        function stopFocus() { return true }
        function startPomodoroWork(id, title, workSeconds) {
            testCase.lastWorkSeconds = workSeconds; mode = 1; phase = 1;
            targetSeconds = workSeconds; remainingSeconds = workSeconds; phaseChanged(); return true
        }
        function startBreak(breakSeconds) { mode = 1; phase = 2; targetSeconds = breakSeconds; phaseChanged(); return true }
    }

    FocusView {
        id: view
        anchors.fill: parent
    }

    // 注入假 focusTimer（覆盖 FocusView 的 timer 默认绑定）
    Component.onCompleted: view.timer = fakeFocusTimer

    function init() {
        fakeFocusTimer.mode = 0; fakeFocusTimer.phase = 0;
        fakeFocusTimer.targetSeconds = 0; fakeFocusTimer.remainingSeconds = 0;
        testCase.lastWorkSeconds = 0;
        view.toPomodoroTab(false);
        wait(50);
    }

    function test_switchToPomodoroShowsPresets() {
        view.toPomodoroTab(true);
        wait(50);
        var startBtn = findChild(view, "pomodoroStartButton");
        verify(startBtn !== null);
        compare(view.state, "pomoIdle");
    }

    function test_startPomodoroUsesSelectedWork() {
        view.toPomodoroTab(true);
        wait(50);
        view.selectWorkMinutes(45);
        view.startPomodoro();
        wait(50);
        compare(testCase.lastWorkSeconds, 45 * 60);
        compare(view.state, "pomoWork");
    }
}
```
> 注：FocusView 暴露一个 `property var focusTimer`（默认绑全局 `focusTimer`，测试可覆盖）+ 测试辅助函数 `toPomodoroTab(bool)`、`selectWorkMinutes(int)`、`startPomodoro()`，见 Step 3。

- [ ] **Step 2：运行测试，确认失败**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL（FocusView 尚无 `state`/辅助函数/`pomodoroStartButton`）。

- [ ] **Step 3：重写 FocusView.qml**

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Item {
    id: root

    signal focusEnded()

    // 默认绑全局上下文属性 focusTimer；命名为 timer 避免与上下文同名导致自引用绑定环。测试可覆盖。
    property var timer: typeof focusTimer !== "undefined" ? focusTimer : null
    property string errorText: ""

    // 番茄 UI 本地状态
    property bool pomodoroTab: false
    property int justCompletedPhase: 0   // 0 无 / 1 专注完成 / 2 休息完成
    property int pomoTaskId: -1
    property string pomoTaskTitle: ""
    property int workSeconds: 25 * 60
    property int breakSeconds: 5 * 60

    readonly property int phaseWork: 1
    readonly property int phaseBreak: 2

    function safeSeconds(value) { return Math.max(0, Number(value || 0)) }
    function formatTime(seconds) {
        var s = root.safeSeconds(seconds)
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
        return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
    }

    // —— 供测试与按钮调用的纯函数，集中状态变更，避免散落 ——
    function toPomodoroTab(on) {
        if (on) {
            // 切到番茄：记住当前任务，结束正在进行的自由会话，进入待机选时长。
            if (root.timer && root.timer.hasActiveSession) {
                root.pomoTaskId = root.timer.currentTaskId
                root.pomoTaskTitle = root.timer.currentTaskTitle
                root.timer.stopFocus()
            } else if (root.timer) {
                root.pomoTaskId = root.timer.currentTaskId
                root.pomoTaskTitle = root.timer.currentTaskTitle
            }
            root.justCompletedPhase = 0
            root.pomodoroTab = true
        } else {
            if (root.timer && root.timer.hasActiveSession) {
                root.timer.stopFocus()
            }
            root.justCompletedPhase = 0
            root.pomodoroTab = false
        }
    }
    function selectWorkMinutes(minutes) { root.workSeconds = minutes * 60 }
    function selectBreakMinutes(minutes) { root.breakSeconds = minutes * 60 }
    function startPomodoro() {
        if (root.pomoTaskId <= 0 || !root.timer) {
            root.errorText = "请先从任务点「开始专注」进入"
            return
        }
        root.justCompletedPhase = 0
        if (root.timer.startPomodoroWork(root.pomoTaskId, root.pomoTaskTitle, root.workSeconds)) {
            root.errorText = ""
        } else {
            root.errorText = "番茄启动失败，请重试"
        }
    }
    function startBreakPhase() {
        root.justCompletedPhase = 0
        if (root.timer) root.timer.startBreak(root.breakSeconds)
    }
    function endPomodoro() {
        if (root.timer && root.timer.hasActiveSession) root.timer.stopFocus()
        root.justCompletedPhase = 0
        root.focusEnded()
    }

    // 番茄阶段倒计时归零：记下完成阶段（驱动到点态），并请求窗口置前（在 main.qml 接 phaseCompleted）。
    Connections {
        target: root.timer
        ignoreUnknownSignals: true
        function onPhaseCompleted(phase) { root.justCompletedPhase = phase }
    }

    // —— 形态状态机 ——
    state: {
        if (!root.pomodoroTab) return "free"
        if (root.justCompletedPhase === root.phaseWork) return "workDone"
        if (root.justCompletedPhase === root.phaseBreak) return "breakDone"
        if (root.timer && root.timer.phase === root.phaseWork) return "pomoWork"
        if (root.timer && root.timer.phase === root.phaseBreak) return "pomoBreak"
        return "pomoIdle"
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.surfaceSunken

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 64, 460)
            spacing: Theme.space24

            // 模式切换（互斥按钮组）
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 0

                ButtonGroup { id: modeGroup }

                Button {
                    id: freeTab
                    text: "自由专注"
                    checkable: true
                    checked: !root.pomodoroTab
                    ButtonGroup.group: modeGroup
                    implicitWidth: 110
                    implicitHeight: 36
                    background: Rectangle {
                        color: freeTab.checked ? Theme.surface : "transparent"
                        border.color: Theme.border
                        border.width: 1
                        radius: Theme.radiusMd
                    }
                    contentItem: Text {
                        text: freeTab.text
                        color: freeTab.checked ? Theme.ink : Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.toPomodoroTab(false)
                }

                Button {
                    id: pomoTab
                    text: "番茄"
                    checkable: true
                    checked: root.pomodoroTab
                    ButtonGroup.group: modeGroup
                    implicitWidth: 110
                    implicitHeight: 36
                    background: Rectangle {
                        color: pomoTab.checked ? Theme.surface : "transparent"
                        border.color: Theme.border
                        border.width: 1
                        radius: Theme.radiusMd
                    }
                    contentItem: Text {
                        text: pomoTab.text
                        color: pomoTab.checked ? Theme.ink : Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.toPomodoroTab(true)
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.pomodoroTab
                      ? (root.pomoTaskTitle.length > 0 ? root.pomoTaskTitle : "尚未选择任务")
                      : (root.timer && root.timer.currentTaskTitle.length > 0
                         ? root.timer.currentTaskTitle : "尚未开始专注")
                font.pixelSize: Theme.fontXl
                font.bold: true
                color: Theme.ink
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            // 番茄待机：选预设
            ColumnLayout {
                id: presetPane
                Layout.fillWidth: true
                spacing: Theme.space12
                visible: false

                Text { Layout.fillWidth: true; text: "专注时长"; color: Theme.inkSoft; font.pixelSize: Theme.fontSm; horizontalAlignment: Text.AlignHCenter }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space8
                    ButtonGroup { id: workGroup }
                    Repeater {
                        model: [25, 45, 60]
                        delegate: Button {
                            required property int modelData
                            text: modelData + " 分"
                            checkable: true
                            checked: root.workSeconds === modelData * 60
                            ButtonGroup.group: workGroup
                            implicitWidth: 80
                            implicitHeight: 38
                            background: Rectangle {
                                color: parent.checked ? Theme.accent : Theme.surface
                                border.color: parent.checked ? Theme.accentStrong : Theme.border
                                border.width: 1
                                radius: Theme.radiusMd
                            }
                            contentItem: Text {
                                text: parent.text
                                color: parent.checked ? Theme.surface : Theme.ink
                                font.pixelSize: Theme.fontMd
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: root.selectWorkMinutes(modelData)
                        }
                    }
                }

                Text { Layout.fillWidth: true; text: "休息"; color: Theme.inkSoft; font.pixelSize: Theme.fontSm; horizontalAlignment: Text.AlignHCenter }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space8
                    ButtonGroup { id: breakGroup }
                    Repeater {
                        model: [5, 10]
                        delegate: Button {
                            required property int modelData
                            text: modelData + " 分"
                            checkable: true
                            checked: root.breakSeconds === modelData * 60
                            ButtonGroup.group: breakGroup
                            implicitWidth: 80
                            implicitHeight: 38
                            background: Rectangle {
                                color: parent.checked ? Theme.accent : Theme.surface
                                border.color: parent.checked ? Theme.accentStrong : Theme.border
                                border.width: 1
                                radius: Theme.radiusMd
                            }
                            contentItem: Text {
                                text: parent.text
                                color: parent.checked ? Theme.surface : Theme.ink
                                font.pixelSize: Theme.fontMd
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: root.selectBreakMinutes(modelData)
                        }
                    }
                }
            }

            // 到点完成横幅（视觉提醒；窗口置前在 main.qml）
            Rectangle {
                id: doneBanner
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                radius: Theme.radiusMd
                color: Theme.surface
                border.color: Theme.accent
                border.width: 1
                visible: false
                opacity: visible ? 1 : 0
                Behavior on opacity { OpacityAnimator { duration: 150 } }
                Text {
                    anchors.centerIn: parent
                    text: root.justCompletedPhase === root.phaseWork ? "🎉 专注完成！" : "休息结束，继续加油"
                    color: Theme.accentStrong
                    font.pixelSize: Theme.fontLg
                    font.bold: true
                }
            }

            // 计时显示：自由=正计时 elapsedSeconds；番茄=倒计时 remainingSeconds
            Text {
                id: timeText
                Layout.fillWidth: true
                text: root.pomodoroTab
                      ? root.formatTime(root.timer ? root.timer.remainingSeconds : 0)
                      : root.formatTime(root.timer ? root.timer.elapsedSeconds : 0)
                font.pixelSize: Theme.fontDisplay
                font.bold: true
                color: Theme.accent
                horizontalAlignment: Text.AlignHCenter
                visible: false
            }

            Text {
                id: statusText
                Layout.fillWidth: true
                font.pixelSize: Theme.fontLg
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
                visible: false
            }

            Text {
                Layout.fillWidth: true
                visible: root.errorText.length > 0
                text: root.errorText
                font.pixelSize: Theme.fontMd
                color: Theme.danger
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            // 操作按钮行（内容随 state 切换）
            RowLayout {
                id: actionRow
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.space16

                Button {
                    id: primaryButton
                    objectName: "pomodoroStartButton"
                    implicitWidth: 120
                    implicitHeight: 40
                    text: "开始专注"
                    background: Rectangle { color: primaryButton.enabled ? Theme.accent : Theme.border; radius: Theme.radiusMd }
                    contentItem: Text {
                        text: primaryButton.text
                        color: primaryButton.enabled ? Theme.surface : Theme.inkMuted
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.primaryAction()
                }

                Button {
                    id: secondaryButton
                    implicitWidth: 104
                    implicitHeight: 40
                    text: "停止"
                    background: Rectangle { color: Theme.inkSoft; radius: Theme.radiusMd }
                    contentItem: Text {
                        text: secondaryButton.text
                        color: Theme.surface
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.secondaryAction()
                }
            }
        }
    }

    // 主/次按钮的行为随 state 改变（集中在这里，按钮文案由 states 设置）
    function primaryAction() {
        switch (root.state) {
        case "free": // 自由：暂停/继续
            if (root.timer && root.timer.isRunning) root.timer.pauseFocus()
            else if (root.timer && !root.timer.resumeFocus()) root.errorText = "专注恢复失败"
            else root.errorText = ""
            break
        case "pomoIdle": root.startPomodoro(); break
        case "pomoWork": case "pomoBreak":
            if (root.timer && root.timer.isRunning) root.timer.pauseFocus()
            else if (root.timer) root.timer.resumeFocus()
            break
        case "workDone": root.startBreakPhase(); break
        case "breakDone": root.startPomodoro(); break
        }
    }
    function secondaryAction() {
        switch (root.state) {
        case "free":
            if (root.timer && root.timer.stopFocus()) { root.errorText = ""; root.focusEnded() }
            else root.errorText = "专注保存失败，请重试"
            break
        case "pomoWork": case "pomoBreak": root.endPomodoro(); break
        case "workDone": case "breakDone": root.endPomodoro(); break
        }
    }

    states: [
        State { name: "free"
            PropertyChanges { timeText.visible: true; statusText.visible: true
                statusText.text: (root.timer && root.timer.isRunning) ? "专注进行中" : "专注已暂停"
                primaryButton.text: (root.timer && root.timer.isRunning) ? "暂停" : "继续"
                primaryButton.enabled: root.timer ? root.timer.hasActiveSession : false
                secondaryButton.text: "结束专注"; secondaryButton.visible: true }
        },
        State { name: "pomoIdle"
            PropertyChanges { presetPane.visible: true
                primaryButton.text: "开始专注"; primaryButton.enabled: root.pomoTaskId > 0
                secondaryButton.visible: false }
        },
        State { name: "pomoWork"
            PropertyChanges { timeText.visible: true; statusText.visible: true; statusText.text: "专注中"
                primaryButton.text: (root.timer && root.timer.isRunning) ? "暂停" : "继续"; primaryButton.enabled: true
                secondaryButton.text: "停止"; secondaryButton.visible: true }
        },
        State { name: "pomoBreak"
            PropertyChanges { timeText.visible: true; statusText.visible: true; statusText.text: "休息中"
                primaryButton.text: (root.timer && root.timer.isRunning) ? "暂停" : "继续"; primaryButton.enabled: true
                secondaryButton.text: "跳过休息"; secondaryButton.visible: true }
        },
        State { name: "workDone"
            PropertyChanges { doneBanner.visible: true; timeText.visible: true
                primaryButton.text: "开始休息"; primaryButton.enabled: true
                secondaryButton.text: "结束"; secondaryButton.visible: true }
        },
        State { name: "breakDone"
            PropertyChanges { doneBanner.visible: true
                primaryButton.text: "开始专注"; primaryButton.enabled: root.pomoTaskId > 0
                secondaryButton.text: "结束"; secondaryButton.visible: true }
        }
    ]
}
```

- [ ] **Step 4：qmllint + 运行 QML 测试**

Run:
```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml
cmake --build build && ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure
```
Expected: qmllint 无 error；QML 测试 PASS（含 `FocusViewDualMode` 两个用例，且 MainWindow 等既有用例不回归——MainWindow 注入的假 focusTimer 在 Task 3 补字段）。

- [ ] **Step 5：提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "FocusView 双模式 UI：自由计时 + 番茄倒计时"
```

---

## Task 3：窗口置前 + MainWindow 测试假对象补字段

**Files:**
- Modify: `qml/main.qml`（`phaseCompleted` → 窗口置前）
- Modify: `tests/qml/tst_mainwindow_ui_optimization.qml`（假 focusTimer 补番茄字段）

**Interfaces:**
- Consumes: Task 1 的 `focusTimer.phaseCompleted`。

- [ ] **Step 1：补 MainWindow 测试假对象（防回归）**

在 `tests/qml/tst_mainwindow_ui_optimization.qml` 的 `QtObject { id: focusTimer ... }` 里，已有 `startFocus/pauseFocus/resumeFocus/stopFocus` 等。补上番茄字段与方法：
```qml
        property int currentTaskId: -1
        property int mode: 0
        property int phase: 0
        property int targetSeconds: 0
        property int remainingSeconds: 0
        signal modeChanged()
        signal phaseChanged()
        signal phaseCompleted(int phase)
        function startPomodoroWork(id, title, workSeconds) { return true }
        function startBreak(breakSeconds) { return true }
```

- [ ] **Step 2：main.qml 接 phaseCompleted 置前窗口**

在 `qml/main.qml` 的 `ApplicationWindow { ... }` 内、`MainWindow { ... }` 之后加：
```qml
    // 番茄阶段到点：把窗口拉到前台提醒用户（无声音，纯视觉 + 置前）。
    Connections {
        target: typeof focusTimer !== "undefined" ? focusTimer : null
        ignoreUnknownSignals: true
        function onPhaseCompleted(phase) {
            root.raise()
            root.requestActivate()
        }
    }
```
（`root` 为 main.qml 的 ApplicationWindow id；若未命名则先加 `id: root`。）

- [ ] **Step 3：qmllint + 全量构建与测试**

Run:
```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/main.qml
cmake --build build
ctest --test-dir build --output-on-failure
```
Expected: qmllint 无 error；三套件全部 PASS。

- [ ] **Step 4：人工冒烟（真机）**

```bash
osascript -e 'quit app "番茄Todo"'; pkill -f "番茄Todo.app"; sleep 1
open "/Applications/番茄Todo.app"
```
检查：任务「开始专注」进入＝自由计时（不变）→ 切「番茄」标签结束自由会话、出现时长预设 → 选 25 分开始 → 倒计时 → 到 0 高亮「专注完成」+ 窗口被拉到前台 → 点「开始休息」倒计时 5 分 → 到 0 提醒 → 点「开始专注」回到专注；自由标签行为与之前一致；25 分番茄完成后任务自动勾完成、统计有记录、休息不计入。

- [ ] **Step 5：提交**

```bash
git add qml/main.qml tests/qml/tst_mainwindow_ui_optimization.qml
git commit -m "番茄到点窗口置前并补全测试假对象"
```

---

## 自检备注

- **Spec 覆盖**：双模式=Task 2（模式切换+自由保留）；番茄状态机/到点结算/休息不写库/3·5 分钟规则复用=Task 1；预设时长=Task 2（ButtonGroup 25/45/60、5/10）；到点视觉提醒=Task 2（doneBanner）+窗口置前=Task 3；存库正确性 C++ 测试=Task 1，QML 测试=Task 2/3。QML 约束（Controls/states/Animator/裸中文/plain import/无 a11y）贯穿 Task 2-3。
- **类型一致性**：`mode/phase/targetSeconds/remainingSeconds/currentTaskId`、`startPomodoroWork(taskId,title,workSeconds)`、`startBreak(breakSeconds)`、`phaseCompleted(int phase)` 在 Task 1 定义，Task 2/3 的 QML 与测试假对象引用一致；phase 取值 1=专注 2=休息 全程统一。
- **向后兼容**：`startFocus/pauseFocus/resumeFocus/stopFocus` 签名不变；自由模式 `mode=0,target=0` 不触发归零结算；MainWindow 既有测试靠 Task 3 补假字段保持通过。
- **不发递归 / 不改表**：番茄不开第二个 Timer（复用 m_elapsedSeconds）；休息段不建会话；无数据库迁移。
