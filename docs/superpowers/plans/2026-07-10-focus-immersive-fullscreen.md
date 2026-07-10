# 专注页全屏沉浸模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 专注页新增一键 macOS 原生全屏沉浸模式——屏幕只留计时与任务名，控制按钮悬停浮现，Esc/✕/专注结束三路退出。

**Architecture:** 新增独立沉浸层 `FocusImmersiveOverlay`（FocusView 运行态的只读投影 + 动作转发，不新增业务状态），`MainWindow.focusImmersiveActive` 为唯一事实源，`main.qml` 经决策对象 `ImmersionWindowSync` 与窗口 visibility 双向同步（含进入过渡护栏）。规格见 `docs/superpowers/specs/2026-07-10-focus-immersive-fullscreen-design.md`。

**Tech Stack:** Qt 6 / QML（QtQuick、QtQuick.Controls Basic 风格）、qmltestrunner（经 ctest）、CMake（Unix Makefiles，build 目录 `build/`）。

## Global Constraints

- **测试铁律：绝不断言 `item.visible === true`**（offscreen 下祖先链级联不可靠）；断言驱动它的源头布尔/文案/信号。断言 `visible === false` 允许（显式 false 不受祖先影响）。
- QML 测试文件放 `tests/qml/tst_*.qml`，由 `qmltestrunner -input` 扫目录**自动发现，无需注册**。
- 跑 QML 测试：`ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`（纯 QML 改动无需重新编译）。
- 构建应用（qrc 变更后需要）：`cmake --build build -j`。
- 颜色/字号/间距一律用 `Theme.*` 令牌，不写裸色值；UI 文案中文。
- 测试 mock 模式：在 TestCase 里声明同名 id 的 `QtObject`（如 `focusTimer`）供被测组件解析。
- 提交信息：中文一句话，与 git log 风格一致。
- 新组件属性/函数名与本计划**逐字一致**（跨任务契约）。

---

### Task 1: FocusView — 提炼 endFreeFocus + 沉浸入口按钮

**Files:**

- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`（扩展现有文件）

**Interfaces:**

- Produces: `signal immersiveRequested()`；`readonly property bool immersiveAvailable`；`function endFreeFocus()`（Task 4 的沉浸层调用它；Task 6 的 MainWindow 连接 `immersiveRequested`）。

- [ ] **Step 1: 写失败测试。** 在 `tests/qml/tst_focus_view.qml` 的 `focusTimer` mock 里，`property int stopFocusCalls: 0` 一行后加：

```qml
        property bool stopFocusFails: false
```

`stopFocus()` 函数整体替换为：

```qml
        function stopFocus() {
            stopFocusCalls += 1
            if (stopFocusFails) {
                return false
            }
            isRunning = false
            hasActiveSession = false
            mode = 0
            phase = 0
            currentTaskId = 0
            currentTaskTitle = ""
            return true
        }
```

在 `FocusView { id: view ... }` 声明之后加两个 SignalSpy：

```qml
    SignalSpy {
        id: focusEndedSpy
        target: view
        signalName: "focusEnded"
    }

    SignalSpy {
        id: immersiveSpy
        target: view
        signalName: "immersiveRequested"
    }
```

`init()` 末尾（`wait(20)` 之前）加：

```qml
        focusTimer.stopFocusFails = false
        focusEndedSpy.clear()
        immersiveSpy.clear()
```

文件末尾（最后一个测试函数后）加四个测试：

```qml
    function test_endFreeFocusStopsSessionAndSignals() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        view.endFreeFocus()

        compare(focusTimer.stopFocusCalls, 1)
        compare(view.errorText, "")
        compare(focusEndedSpy.count, 1)
    }

    function test_endFreeFocusFailureShowsErrorWithoutSignal() {
        focusTimer.hasActiveSession = true
        focusTimer.stopFocusFails = true
        wait(20)

        view.endFreeFocus()

        compare(view.errorText, "专注保存失败，请重试")
        compare(focusEndedSpy.count, 0)
    }

    function test_immersiveAvailableOnlyWhileTiming() {
        // 自由模式无会话：不可进沉浸。
        compare(view.immersiveAvailable, false)

        // 自由模式有会话（含暂停）：可进。
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = false
        wait(20)
        compare(view.immersiveAvailable, true)

        // 番茄待机：不可进。
        focusTimer.hasActiveSession = false
        view.toPomodoroTab(true)
        wait(20)
        compare(view.state, "pomoIdle")
        compare(view.immersiveAvailable, false)

        // 番茄工作中：可进。
        view.startPomodoro()
        wait(20)
        compare(view.state, "pomoWork")
        compare(view.immersiveAvailable, true)

        // 工作完成态：不可进（完成态按钮常驻，无需先全屏）。
        focusTimer.phaseCompleted(1)
        wait(20)
        compare(view.state, "workDone")
        compare(view.immersiveAvailable, false)
    }

    function test_immersiveButtonEmitsRequest() {
        const button = findChild(view, "immersiveButton")
        verify(button)
        button.clicked()
        compare(immersiveSpy.count, 1)
    }
```

- [ ] **Step 2: 跑测试确认失败。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL，报 `view.endFreeFocus is not a function`、`immersiveAvailable` 为 undefined 的 compare 失败、`immersiveButton` 找不到。

- [ ] **Step 3: 实现。** `qml/views/FocusView.qml`：

3a. `signal focusEnded()` 之后加：

```qml
    signal immersiveRequested()

    // 沉浸入口只在计时进行中（含暂停）开放：待机/完成/未开始要么需要配置面板，
    // 要么即将离开专注页，极简全屏没有意义。
    readonly property bool immersiveAvailable: state === "pomoWork" || state === "pomoBreak"
            || (state === "free" && timerBool("hasActiveSession"))
```

3b. `endPomodoro()` 函数之后加：

```qml
    function endFreeFocus() {
        // 自由模式结束逻辑单点：页面按钮与沉浸层共用，避免两处复制。
        if (root.timer && root.timer.stopFocus()) {
            root.errorText = ""
            root.clearPomodoroTask()
            root.focusEnded()
        } else {
            root.errorText = "专注保存失败，请重试"
        }
    }
```

3c. `freeStopButton` 的 `onClicked` 整段替换为：

```qml
                    onClicked: root.endFreeFocus()
```

3d. `soundToggleButton` 声明之后（同为 backdrop Rectangle 的子项）加：

```qml
        Button {
            id: immersiveButton
            objectName: "immersiveButton"

            anchors.top: parent.top
            anchors.right: soundToggleButton.left
            anchors.topMargin: Theme.space16
            anchors.rightMargin: Theme.space8
            implicitWidth: 40
            implicitHeight: 32
            visible: root.immersiveAvailable

            onClicked: root.immersiveRequested()

            background: Rectangle {
                color: immersiveButton.hovered ? Theme.surface : "transparent"
                border.color: immersiveButton.hovered ? Theme.border : "transparent"
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: "⛶"
                font.pixelSize: Theme.fontLg
                color: Theme.ink
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
```

- [ ] **Step 4: 跑测试确认通过。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（含原有全部测试——`test_switchingDirectPomodoroTaskToFreeStartsFocus` 等回归不许挂）。

- [ ] **Step 5: Commit。**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "专注页提炼自由结束逻辑并新增沉浸入口"
```

---

### Task 2: FocusImmersiveOverlay 骨架 — 状态投影

**Files:**

- Create: `qml/components/FocusImmersiveOverlay.qml`
- Modify: `resources/qml.qrc`
- Test: Create `tests/qml/tst_focus_immersive.qml`

**Interfaces:**

- Consumes: FocusView 的 `state`、`errorText` 与函数 `primaryTimeText/pomodoroStageText/runningText/taskTitle/ringProgressFraction/ringColorForState/ringDimmed/ringCaptionText/ringTimeMarkup/primaryTimeColor`（Task 1 前已存在）。
- Produces: 组件属性 `focusViewRef/timerRef/settingsRef/active`、`readonly` 派生 `projectedState/completionState/sessionPaused/projectable`；objectName `immersiveBackdrop/immersiveRing/immersiveRingTimeText/immersiveFreeTimeText/immersiveTaskText/immersiveStageText/immersiveBannerText/immersiveErrorText`。Task 3/4 在此文件上追加。

- [ ] **Step 1: 写失败测试。** 新建 `tests/qml/tst_focus_immersive.qml`：

```qml
import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"

TestCase {
    id: testCase
    name: "FocusImmersiveOverlay"
    when: windowShown
    width: 900
    height: 640

    QtObject {
        id: focusViewStub

        property string state: "pomoWork"
        property string errorText: ""
        property string timeText: "12:34"
        property real progressValue: 0.5
        property color ringColorValue: Theme.accent
        property bool dimmedValue: false
        property string captionText: "剩余 · 共 25 分"
        property string stageText: "专注中"
        property string runningLine: "专注进行中"
        property string titleText: "写周报"
        property bool canStart: true
        property int togglePauseCalls: 0
        property int endPomodoroCalls: 0
        property int startBreakCalls: 0
        property int startPomodoroCalls: 0
        property int endFreeFocusCalls: 0

        function primaryTimeText() { return timeText }
        function pomodoroStageText() { return stageText }
        function runningText() { return runningLine }
        function taskTitle() { return titleText }
        function ringProgressFraction() { return progressValue }
        function ringColorForState() { return ringColorValue }
        function ringDimmed() { return dimmedValue }
        function ringCaptionText() { return captionText }
        function primaryTimeColor() { return dimmedValue ? Theme.inkMuted : Theme.accentInk }
        function ringTimeMarkup(plain) { return plain }
        function canStartPomodoro() { return canStart }
        function togglePause() { togglePauseCalls += 1 }
        function endPomodoro() { endPomodoroCalls += 1 }
        function startBreak() { startBreakCalls += 1 }
        function startPomodoro() { startPomodoroCalls += 1 }
        function endFreeFocus() { endFreeFocusCalls += 1 }
    }

    QtObject {
        id: timerStub

        property bool isRunning: true
        property bool hasActiveSession: true
        property int phase: 1
    }

    QtObject {
        id: settingsStub

        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
    }

    FocusImmersiveOverlay {
        id: overlay
        width: testCase.width
        height: testCase.height
        focusViewRef: focusViewStub
        timerRef: timerStub
        settingsRef: settingsStub
        active: true
    }

    function init() {
        focusViewStub.state = "pomoWork"
        focusViewStub.errorText = ""
        focusViewStub.timeText = "12:34"
        focusViewStub.progressValue = 0.5
        focusViewStub.ringColorValue = Theme.accent
        focusViewStub.dimmedValue = false
        focusViewStub.stageText = "专注中"
        focusViewStub.titleText = "写周报"
        focusViewStub.canStart = true
        focusViewStub.togglePauseCalls = 0
        focusViewStub.endPomodoroCalls = 0
        focusViewStub.startBreakCalls = 0
        focusViewStub.startPomodoroCalls = 0
        focusViewStub.endFreeFocusCalls = 0
        timerStub.isRunning = true
        timerStub.hasActiveSession = true
        timerStub.phase = 1
        settingsStub.reduceMotion = false
        settingsStub.slimClockFont = true
        settingsStub.soundEnabled = true
        overlay.active = true
        wait(20)
    }

    function test_backdropUsesGlassToken() {
        const backdrop = findChild(overlay, "immersiveBackdrop")
        verify(backdrop)
        verify(Qt.colorEqual(backdrop.color, Theme.glassCard))
    }

    function test_pomoWorkProjectsRingAndTexts() {
        const ring = findChild(overlay, "immersiveRing")
        verify(ring)
        compare(ring.showPreview, false)
        compare(ring.dimmed, false)
        verify(Math.abs(ring.progress - 0.5) < 0.001)
        verify(Qt.colorEqual(ring.ringColor, Theme.accent))

        const time = findChild(overlay, "immersiveRingTimeText")
        verify(time)
        compare(time.text, "12:34")
        compare(time.font.family, Theme.fontFamilyClock)

        const title = findChild(overlay, "immersiveTaskText")
        verify(title)
        compare(title.text, "写周报")

        const stage = findChild(overlay, "immersiveStageText")
        verify(stage)
        compare(stage.text, "专注中")

        compare(overlay.projectedState, "pomoWork")
        compare(overlay.completionState, false)
        compare(overlay.projectable, true)
    }

    function test_freeProjectsBigClock() {
        focusViewStub.state = "free"
        focusViewStub.timeText = "01:02:03"
        focusViewStub.stageText = "当前任务"
        wait(20)

        const freeTime = findChild(overlay, "immersiveFreeTimeText")
        verify(freeTime)
        compare(freeTime.text, "01:02:03")

        const stage = findChild(overlay, "immersiveStageText")
        verify(stage)
        compare(stage.text, "专注进行中")

        compare(overlay.projectable, true)
    }

    function test_completionShowsBanner() {
        focusViewStub.state = "workDone"
        focusViewStub.stageText = "专注完成"
        focusViewStub.progressValue = 1
        focusViewStub.ringColorValue = Theme.success
        wait(20)

        compare(overlay.completionState, true)

        const banner = findChild(overlay, "immersiveBannerText")
        verify(banner)
        compare(banner.text, "专注完成")

        const ring = findChild(overlay, "immersiveRing")
        verify(ring)
        compare(ring.progress, 1)
        verify(Qt.colorEqual(ring.ringColor, Theme.success))
    }

    function test_errorTextProjected() {
        focusViewStub.errorText = "番茄结束失败，请重试"
        wait(20)

        const error = findChild(overlay, "immersiveErrorText")
        verify(error)
        compare(error.text, "番茄结束失败，请重试")
        verify(Qt.colorEqual(error.color, Theme.danger))
    }

    function test_sessionPausedAcrossStates() {
        timerStub.isRunning = false
        compare(overlay.sessionPaused, true)

        focusViewStub.state = "free"
        compare(overlay.sessionPaused, true)

        timerStub.hasActiveSession = false
        compare(overlay.sessionPaused, false)

        focusViewStub.state = "workDone"
        compare(overlay.sessionPaused, false)
    }

    function test_projectableRejectsIdleAndEmptyFree() {
        focusViewStub.state = "pomoIdle"
        compare(overlay.projectable, false)

        focusViewStub.state = "free"
        timerStub.hasActiveSession = false
        compare(overlay.projectable, false)

        focusViewStub.state = "breakDone"
        compare(overlay.projectable, true)
    }

    function test_clockFollowsSlimSetting() {
        const time = findChild(overlay, "immersiveRingTimeText")
        verify(time)
        compare(time.font.weight, Font.Light)

        settingsStub.slimClockFont = false
        compare(time.font.weight, Font.Medium)
    }
}
```

- [ ] **Step 2: 跑测试确认失败。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL，`FocusImmersiveOverlay is not a type`。

- [ ] **Step 3: 实现。** 新建 `qml/components/FocusImmersiveOverlay.qml`：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

// 全屏沉浸层：FocusView 运行态的只读投影 + 动作转发。
// 自身不持有业务状态；唯一事实源是 MainWindow.focusImmersiveActive（经 active 传入）。
// 时间/文案/环参数全部经 focusViewRef 的既有函数取得，不复制格式化与状态逻辑。
Item {
    id: root

    property var focusViewRef: null
    property var timerRef: null
    property var settingsRef: null
    property bool active: false

    readonly property string projectedState: focusViewRef ? String(focusViewRef.state) : ""
    readonly property bool completionState: projectedState === "workDone" || projectedState === "breakDone"

    readonly property bool sessionPaused: {
        if (!timerRef || Boolean(timerRef.isRunning)) {
            return false
        }
        if (projectedState === "pomoWork" || projectedState === "pomoBreak") {
            return true
        }
        return projectedState === "free" && Boolean(timerRef.hasActiveSession)
    }

    // 无可投影状态（待机/无会话自由态）不呈现空画面；退出联动在 Task 4 接上。
    readonly property bool projectable: {
        if (!focusViewRef || !timerRef) {
            return false
        }
        if (projectedState === "pomoWork" || projectedState === "pomoBreak" || completionState) {
            return true
        }
        return projectedState === "free" && Boolean(timerRef.hasActiveSession)
    }

    function viewText(name) {
        // 投影函数统一走这一层空值防御：focusViewRef 缺席时给空串，不抛错。
        return focusViewRef ? String(focusViewRef[name]()) : ""
    }

    Rectangle {
        objectName: "immersiveBackdrop"

        anchors.fill: parent
        // 与专注页同一块玻璃底板：RowLayout 隐藏后直接坐在壁纸上，材质延续。
        color: Theme.glassCard

        ColumnLayout {
            width: Math.min(parent.width - 96, 640)
            spacing: Theme.space16

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredHeight: 44
                Layout.preferredWidth: bannerText.implicitWidth + Theme.space24 * 2
                visible: root.completionState
                color: Theme.accentSoft
                border.color: Theme.accent
                radius: Theme.radiusMd

                Text {
                    id: bannerText
                    objectName: "immersiveBannerText"

                    anchors.centerIn: parent
                    text: root.viewText("pomodoroStageText")
                    font.pixelSize: Theme.fontLg
                    font.bold: true
                    color: Theme.inkStrong
                }
            }

            FocusRing {
                objectName: "immersiveRing"

                Layout.alignment: Qt.AlignHCenter
                visible: root.projectedState !== "free"
                implicitWidth: 340
                implicitHeight: implicitWidth
                showPreview: false
                dimmed: root.focusViewRef ? Boolean(root.focusViewRef.ringDimmed()) : false
                progress: root.focusViewRef ? Number(root.focusViewRef.ringProgressFraction()) : 1
                ringColor: root.focusViewRef ? root.focusViewRef.ringColorForState() : Theme.accent

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Theme.space4

                    Text {
                        objectName: "immersiveRingTimeText"

                        Layout.alignment: Qt.AlignHCenter
                        text: root.focusViewRef
                              ? String(root.focusViewRef.ringTimeMarkup(root.focusViewRef.primaryTimeText()))
                              : ""
                        textFormat: Text.StyledText
                        font.pixelSize: 72
                        font.family: Theme.fontFamilyClock
                        font.weight: (root.settingsRef && root.settingsRef.slimClockFont) ? Font.Light : Font.Medium
                        color: root.focusViewRef ? root.focusViewRef.primaryTimeColor() : Theme.accentInk
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.viewText("ringCaptionText")
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkSoft
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Text {
                objectName: "immersiveFreeTimeText"

                Layout.fillWidth: true
                visible: root.projectedState === "free"
                text: root.viewText("primaryTimeText")
                textFormat: Text.PlainText
                font.pixelSize: 88
                font.family: Theme.fontFamilyClock
                font.weight: (root.settingsRef && root.settingsRef.slimClockFont) ? Font.Light : Font.Medium
                color: root.focusViewRef ? root.focusViewRef.primaryTimeColor() : Theme.accentInk
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                objectName: "immersiveTaskText"

                Layout.fillWidth: true
                text: root.viewText("taskTitle")
                font.pixelSize: Theme.fontXl
                font.bold: true
                color: Theme.ink
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Text {
                objectName: "immersiveStageText"

                Layout.fillWidth: true
                visible: !root.completionState
                text: root.projectedState === "free"
                      ? root.viewText("runningText")
                      : root.viewText("pomodoroStageText")
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                objectName: "immersiveErrorText"

                Layout.fillWidth: true
                text: root.focusViewRef ? String(root.focusViewRef.errorText) : ""
                visible: text.length > 0
                font.pixelSize: Theme.fontMd
                color: Theme.danger
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
```

3b. `resources/qml.qrc` 里 `FocusRing.qml` 一行后加：

```xml
        <file alias="qml/components/FocusImmersiveOverlay.qml">../qml/components/FocusImmersiveOverlay.qml</file>
```

- [ ] **Step 4: 跑测试确认通过。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5: 确认应用仍能构建（qrc 变更）。**

Run: `cmake --build build -j`
Expected: 构建成功无错误。

- [ ] **Step 6: Commit。**

```bash
git add qml/components/FocusImmersiveOverlay.qml resources/qml.qrc tests/qml/tst_focus_immersive.qml
git commit -m "新增沉浸层组件投影专注状态"
```

---

### Task 3: 沉浸层悬停显控状态机

**Files:**

- Modify: `qml/components/FocusImmersiveOverlay.qml`
- Test: `tests/qml/tst_focus_immersive.qml`（追加）

**Interfaces:**

- Produces: `property bool controlsRevealed`；`readonly property bool controlsPinned/controlsShown/fadeAnimated`；`readonly property alias hideTimerRunning`；`function revealControls()/hideControls()`；objectName `immersiveHoverArea`。Task 4 的按钮容器绑定 `controlsShown`。

- [ ] **Step 1: 写失败测试。** `tests/qml/tst_focus_immersive.qml` 末尾追加：

```qml
    function test_revealControlsStartsHideCountdown() {
        compare(overlay.controlsRevealed, false)
        overlay.revealControls()
        compare(overlay.controlsRevealed, true)
        compare(overlay.hideTimerRunning, true)

        overlay.hideControls()
        compare(overlay.controlsRevealed, false)
        compare(overlay.controlsShown, false)
    }

    function test_controlsPinnedWhenPausedOrDone() {
        compare(overlay.controlsPinned, false)

        timerStub.isRunning = false
        compare(overlay.controlsPinned, true)
        compare(overlay.controlsShown, true)

        timerStub.isRunning = true
        focusViewStub.state = "breakDone"
        compare(overlay.controlsPinned, true)

        focusViewStub.state = "pomoWork"
        compare(overlay.controlsPinned, false)
    }

    function test_cursorHidesWithControls() {
        const hover = findChild(overlay, "immersiveHoverArea")
        verify(hover)
        compare(hover.cursorShape, Qt.BlankCursor)

        overlay.revealControls()
        compare(hover.cursorShape, Qt.ArrowCursor)
    }

    function test_fadeAnimatedFollowsReduceMotion() {
        compare(overlay.fadeAnimated, true)
        settingsStub.reduceMotion = true
        compare(overlay.fadeAnimated, false)
    }
```

同时在 `init()` 里 `overlay.active = true` 之前加一行复位：

```qml
        overlay.controlsRevealed = false
```

- [ ] **Step 2: 跑测试确认失败。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL，`revealControls is not a function` / `controlsPinned` undefined。

- [ ] **Step 3: 实现。** `FocusImmersiveOverlay.qml`：

3a. `readonly property bool projectable` 块之后加：

```qml
    // 悬停显控：鼠标动 → 浮现并重启 3 秒倒计时；暂停/完成态常驻不淡出。
    property bool controlsRevealed: false
    readonly property bool controlsPinned: sessionPaused || completionState
    readonly property bool controlsShown: controlsRevealed || controlsPinned
    readonly property bool fadeAnimated: !(settingsRef && settingsRef.reduceMotion)
    readonly property alias hideTimerRunning: hideTimer.running

    function revealControls() {
        controlsRevealed = true
        hideTimer.restart()
    }

    function hideControls() {
        controlsRevealed = false
    }
```

3b. `function viewText(name)` 块之后加：

```qml
    Timer {
        id: hideTimer

        interval: 3000
        onTriggered: root.hideControls()
    }
```

3c. `Rectangle { objectName: "immersiveBackdrop"` 内、`ColumnLayout` 之前加：

```qml
        MouseArea {
            objectName: "immersiveHoverArea"

            anchors.fill: parent
            hoverEnabled: true
            // 只监听移动不吃点击：按钮浮现后点击要穿透到按钮本身。
            acceptedButtons: Qt.NoButton
            cursorShape: root.controlsShown ? Qt.ArrowCursor : Qt.BlankCursor

            onPositionChanged: root.revealControls()
        }
```

- [ ] **Step 4: 跑测试确认通过。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5: Commit。**

```bash
git add qml/components/FocusImmersiveOverlay.qml tests/qml/tst_focus_immersive.qml
git commit -m "沉浸层悬停显控与光标隐藏"
```

---

### Task 4: 沉浸层按钮、动作转发与退出

**Files:**

- Modify: `qml/components/FocusImmersiveOverlay.qml`
- Test: `tests/qml/tst_focus_immersive.qml`（追加）

**Interfaces:**

- Consumes: Task 1 的 `focusViewRef.endFreeFocus()`；Task 3 的 `controlsShown/fadeAnimated`。
- Produces: `signal exitRequested()`；`function requestExit()/triggerPrimary()/triggerSecondary()`；`readonly property string primaryButtonText/secondaryButtonText`；`readonly property bool primaryButtonEnabled`；objectName `immersivePrimaryButton/immersiveSecondaryButton/immersiveSoundButton/immersiveExitButton`。MainWindow（Task 6）连接 `exitRequested`。

- [ ] **Step 1: 写失败测试。** `tests/qml/tst_focus_immersive.qml`：在 `FocusImmersiveOverlay { id: overlay ... }` 之后加：

```qml
    SignalSpy {
        id: exitSpy
        target: overlay
        signalName: "exitRequested"
    }
```

`init()` 末尾 `wait(20)` 前加 `exitSpy.clear()`。文件末尾追加：

```qml
    function test_buttonMappingPerState() {
        // pomoWork 运行中：暂停 / 结束。
        compare(overlay.primaryButtonText, "暂停")
        compare(overlay.primaryButtonEnabled, true)
        compare(overlay.secondaryButtonText, "结束")

        // 暂停中文案翻转。
        timerStub.isRunning = false
        compare(overlay.primaryButtonText, "继续")

        // pomoBreak：跳过休息。
        timerStub.isRunning = true
        focusViewStub.state = "pomoBreak"
        compare(overlay.secondaryButtonText, "跳过休息")

        // free：结束专注；enabled 跟 hasActiveSession。
        focusViewStub.state = "free"
        compare(overlay.secondaryButtonText, "结束专注")
        compare(overlay.primaryButtonEnabled, true)
        timerStub.hasActiveSession = false
        compare(overlay.primaryButtonEnabled, false)

        // workDone：开始休息常亮。
        timerStub.hasActiveSession = true
        focusViewStub.state = "workDone"
        compare(overlay.primaryButtonText, "开始休息")
        compare(overlay.primaryButtonEnabled, true)

        // breakDone：开始专注，enabled 镜像 canStartPomodoro()。
        focusViewStub.state = "breakDone"
        compare(overlay.primaryButtonText, "开始专注")
        compare(overlay.primaryButtonEnabled, true)
        focusViewStub.canStart = false
        compare(overlay.primaryButtonEnabled, false)
    }

    function test_actionsForwardToFocusView() {
        overlay.triggerPrimary()
        compare(focusViewStub.togglePauseCalls, 1)

        overlay.triggerSecondary()
        compare(focusViewStub.endPomodoroCalls, 1)

        focusViewStub.state = "workDone"
        overlay.triggerPrimary()
        compare(focusViewStub.startBreakCalls, 1)

        focusViewStub.state = "breakDone"
        overlay.triggerPrimary()
        compare(focusViewStub.startPomodoroCalls, 1)

        focusViewStub.state = "free"
        overlay.triggerSecondary()
        compare(focusViewStub.endFreeFocusCalls, 1)
    }

    function test_exitPathsEmitSignal() {
        overlay.requestExit()
        compare(exitSpy.count, 1)

        const exitButton = findChild(overlay, "immersiveExitButton")
        verify(exitButton)
        exitButton.clicked()
        compare(exitSpy.count, 2)
    }

    function test_soundButtonFlipsSetting() {
        const sound = findChild(overlay, "immersiveSoundButton")
        verify(sound)
        sound.clicked()
        compare(settingsStub.soundEnabled, false)
        sound.clicked()
        compare(settingsStub.soundEnabled, true)
    }

    function test_unprojectableStateAutoExits() {
        focusViewStub.state = "pomoIdle"
        wait(20)
        compare(exitSpy.count, 1)
    }

    function test_activationIntoUnprojectableStateAutoExits() {
        overlay.active = false
        focusViewStub.state = "pomoIdle"
        wait(20)
        exitSpy.clear()

        overlay.active = true
        wait(20)
        compare(exitSpy.count, 1)
    }
```

- [ ] **Step 2: 跑测试确认失败。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL，`primaryButtonText` undefined / `requestExit is not a function`。

- [ ] **Step 3: 实现。** `FocusImmersiveOverlay.qml`：

3a. `signal` 区（`property bool active` 之后）加：

```qml
    signal exitRequested()
```

3b. `hideControls()` 函数后加：

```qml
    function requestExit() {
        root.exitRequested()
    }

    // 防御：沉浸中落入无可投影状态（如意外回到待机）直接请求退出，不呈现空画面。
    onProjectableChanged: {
        if (active && !projectable) {
            requestExit()
        }
    }

    onActiveChanged: {
        if (active && !projectable) {
            requestExit()
        }
    }

    // 按钮语义按状态映射；enabled 逐一镜像 FocusView 对应按钮，防止休息后任务上下文
    // 已丢时「开始专注」误亮。
    readonly property string primaryButtonText: {
        if (projectedState === "workDone") {
            return "开始休息"
        }
        if (projectedState === "breakDone") {
            return "开始专注"
        }
        return timerRef && timerRef.isRunning ? "暂停" : "继续"
    }

    readonly property bool primaryButtonEnabled: {
        if (projectedState === "workDone") {
            return true
        }
        if (projectedState === "breakDone") {
            return focusViewRef ? Boolean(focusViewRef.canStartPomodoro()) : false
        }
        if (projectedState === "free") {
            return timerRef ? Boolean(timerRef.hasActiveSession) : false
        }
        return timerRef ? Number(timerRef.phase || 0) !== 0 : false
    }

    readonly property string secondaryButtonText: {
        if (projectedState === "pomoBreak") {
            return "跳过休息"
        }
        if (projectedState === "free") {
            return "结束专注"
        }
        return "结束"
    }

    function triggerPrimary() {
        if (!focusViewRef) {
            return
        }
        if (projectedState === "workDone") {
            focusViewRef.startBreak()
            return
        }
        if (projectedState === "breakDone") {
            focusViewRef.startPomodoro()
            return
        }
        focusViewRef.togglePause()
    }

    function triggerSecondary() {
        if (!focusViewRef) {
            return
        }
        if (projectedState === "free") {
            focusViewRef.endFreeFocus()
            return
        }
        focusViewRef.endPomodoro()
    }
```

3c. `Timer { id: hideTimer ... }` 之后加：

```qml
    Shortcut {
        sequence: "Esc"
        enabled: root.active
        onActivated: root.requestExit()
    }
```

3d. backdrop Rectangle 内、`ColumnLayout` 之后（作兄弟项）加两组控制：

```qml
        RowLayout {
            id: topControls

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Theme.space16
            spacing: Theme.space8
            opacity: root.controlsShown ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
                enabled: root.fadeAnimated
                NumberAnimation { duration: 180 }
            }

            Button {
                id: immersiveSoundButton
                objectName: "immersiveSoundButton"

                implicitWidth: 40
                implicitHeight: 32

                onClicked: {
                    if (root.settingsRef) {
                        root.settingsRef.soundEnabled = !root.settingsRef.soundEnabled
                    }
                }

                background: Rectangle {
                    color: immersiveSoundButton.hovered ? Theme.surface : "transparent"
                    border.color: immersiveSoundButton.hovered ? Theme.border : "transparent"
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: root.settingsRef && root.settingsRef.soundEnabled ? "🔔" : "🔕"
                    font.pixelSize: Theme.fontLg
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: immersiveExitButton
                objectName: "immersiveExitButton"

                implicitWidth: 40
                implicitHeight: 32

                onClicked: root.requestExit()

                background: Rectangle {
                    color: immersiveExitButton.hovered ? Theme.surface : "transparent"
                    border.color: immersiveExitButton.hovered ? Theme.border : "transparent"
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: "✕"
                    font.pixelSize: Theme.fontLg
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        RowLayout {
            id: bottomControls

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.space32
            spacing: Theme.space16
            opacity: root.controlsShown ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
                enabled: root.fadeAnimated
                NumberAnimation { duration: 180 }
            }

            Button {
                id: immersivePrimaryButton
                objectName: "immersivePrimaryButton"

                implicitWidth: 112
                implicitHeight: 40
                enabled: root.primaryButtonEnabled

                onClicked: root.triggerPrimary()

                background: Rectangle {
                    color: immersivePrimaryButton.enabled
                           ? (root.completionState ? Theme.accent : Theme.inkSoft)
                           : Theme.border
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: root.primaryButtonText
                    color: immersivePrimaryButton.enabled ? Theme.surface : Theme.inkMuted
                    font.pixelSize: Theme.fontLg
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: immersiveSecondaryButton
                objectName: "immersiveSecondaryButton"

                implicitWidth: 112
                implicitHeight: 40

                onClicked: root.triggerSecondary()

                background: Rectangle {
                    color: root.completionState ? Theme.inkSoft : Theme.accent
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: root.secondaryButtonText
                    color: Theme.surface
                    font.pixelSize: Theme.fontLg
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
```

- [ ] **Step 4: 跑测试确认通过。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS（Task 2/3 的既有沉浸测试也不许挂）。

- [ ] **Step 5: Commit。**

```bash
git add qml/components/FocusImmersiveOverlay.qml tests/qml/tst_focus_immersive.qml
git commit -m "沉浸层动作转发与三路退出"
```

---

### Task 5: ImmersionWindowSync 窗口同步决策对象

**Files:**

- Create: `qml/components/ImmersionWindowSync.qml`
- Modify: `resources/qml.qrc`
- Test: Create `tests/qml/tst_immersion_sync.qml`

**Interfaces:**

- Produces: `property int preImmersiveVisibility`；`property bool enteringFullScreen`；`function visibilityForImmersiveChange(active, currentVisibility) -> int`；`function immersiveActiveAfterVisibilityChange(visibility, active) -> bool`。Task 6 的 main.qml 调用这两个函数。

- [ ] **Step 1: 写失败测试。** 新建 `tests/qml/tst_immersion_sync.qml`：

```qml
import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "ImmersionWindowSync"

    ImmersionWindowSync {
        id: sync
    }

    function init() {
        sync.preImmersiveVisibility = Window.Windowed
        sync.enteringFullScreen = false
    }

    function test_enterFromWindowedRequestsFullScreen() {
        const target = sync.visibilityForImmersiveChange(true, Window.Windowed)
        compare(target, Window.FullScreen)
        compare(sync.preImmersiveVisibility, Window.Windowed)
        compare(sync.enteringFullScreen, true)
    }

    function test_fullScreenObservationClearsGuardAndKeepsActive() {
        sync.visibilityForImmersiveChange(true, Window.Windowed)
        compare(sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true), true)
        compare(sync.enteringFullScreen, false)
    }

    function test_systemExitDeactivatesAfterGuardCleared() {
        sync.visibilityForImmersiveChange(true, Window.Windowed)
        sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true)

        compare(sync.immersiveActiveAfterVisibilityChange(Window.Windowed, true), false)
    }

    function test_guardIgnoresIntermediateStatesDuringEntry() {
        sync.visibilityForImmersiveChange(true, Window.Maximized)

        // 进入过渡中吐出的中间 Windowed 不判为系统退出。
        compare(sync.immersiveActiveAfterVisibilityChange(Window.Windowed, true), true)
        compare(sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true), true)
        compare(sync.enteringFullScreen, false)
    }

    function test_exitRestoresSavedVisibility() {
        sync.visibilityForImmersiveChange(true, Window.Maximized)
        sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true)

        compare(sync.visibilityForImmersiveChange(false, Window.FullScreen), Window.Maximized)
        compare(sync.enteringFullScreen, false)
    }

    function test_alreadyFullScreenEntryKeepsFullScreenOnExit() {
        // 用户本来就在原生全屏：进入不挂护栏（无过渡可等），退出保持全屏只收覆盖层。
        const target = sync.visibilityForImmersiveChange(true, Window.FullScreen)
        compare(target, Window.FullScreen)
        compare(sync.enteringFullScreen, false)

        compare(sync.visibilityForImmersiveChange(false, Window.FullScreen), Window.FullScreen)
    }

    function test_cancelBeforeFullScreenRearmsGuard() {
        sync.visibilityForImmersiveChange(true, Window.Windowed)
        compare(sync.enteringFullScreen, true)

        // 过渡完成前用户已 Esc 退出：护栏必须复位，否则后续系统退出检测永久失效。
        sync.visibilityForImmersiveChange(false, Window.Windowed)
        compare(sync.enteringFullScreen, false)
        compare(sync.immersiveActiveAfterVisibilityChange(Window.Windowed, false), false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL，`ImmersionWindowSync is not a type`。

- [ ] **Step 3: 实现。** 新建 `qml/components/ImmersionWindowSync.qml`：

```qml
import QtQuick

// 沉浸开关 ⇄ 窗口 visibility 的双向同步决策，抽成无副作用对象以便 offscreen 单测：
// main.qml 只负责把返回值赋给 window.visibility / 归零事实源，不含分支逻辑。
QtObject {
    id: sync

    property int preImmersiveVisibility: Window.Windowed
    // 进入过渡护栏：macOS 全屏切换是异步的，首次观察到 FullScreen 之前，
    // 中间态 visibility 事件不得判为「系统侧退出」，否则进入动画途中会自我取消。
    property bool enteringFullScreen: false

    // 沉浸开关变化时窗口应取的 visibility；调用方赋给 window.visibility。
    function visibilityForImmersiveChange(active, currentVisibility) {
        if (active) {
            preImmersiveVisibility = currentVisibility
            // 已在原生全屏则无过渡可等：护栏不挂起，绿灯退出仍能被立即识别。
            enteringFullScreen = currentVisibility !== Window.FullScreen
            return Window.FullScreen
        }
        // 过渡完成前就退出：护栏必须复位，否则系统退出检测永久失效。
        enteringFullScreen = false
        if (preImmersiveVisibility === Window.FullScreen) {
            // 用户原本就在全屏：退出沉浸只收覆盖层，不把人踢出他自己选的全屏。
            return Window.FullScreen
        }
        return preImmersiveVisibility
    }

    // visibility 变化后沉浸是否应保持激活；返回 false 时调用方归零事实源。
    function immersiveActiveAfterVisibilityChange(visibility, active) {
        if (visibility === Window.FullScreen) {
            enteringFullScreen = false
            return active
        }
        if (enteringFullScreen) {
            return active
        }
        return false
    }
}
```

3b. `resources/qml.qrc` 里 `FocusImmersiveOverlay.qml` 一行后加：

```xml
        <file alias="qml/components/ImmersionWindowSync.qml">../qml/components/ImmersionWindowSync.qml</file>
```

- [ ] **Step 4: 跑测试确认通过。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS。

- [ ] **Step 5: Commit。**

```bash
git add qml/components/ImmersionWindowSync.qml resources/qml.qrc tests/qml/tst_immersion_sync.qml
git commit -m "新增窗口沉浸同步决策对象"
```

---

### Task 6: MainWindow 与 main.qml 接线

**Files:**

- Modify: `qml/MainWindow.qml`
- Modify: `qml/main.qml`
- Test: `tests/qml/tst_mainwindow_ui_optimization.qml`（扩展——MainWindow 级 mock 全套已在此文件）

**Interfaces:**

- Consumes: Task 1 `immersiveRequested`、Task 2-4 `FocusImmersiveOverlay`（`active/focusViewRef/timerRef/settingsRef/exitRequested`）、Task 5 `ImmersionWindowSync` 两函数。
- Produces: `MainWindow.focusImmersiveActive: bool`（main.qml 监听）；RowLayout objectName `mainContentRow`；overlay objectName `focusImmersiveOverlay`。

- [ ] **Step 1: 写失败测试。** `tests/qml/tst_mainwindow_ui_optimization.qml` 末尾追加（该文件 `focusTimer` mock 已有 `hasActiveSession/isRunning/phase`）：

```qml
    function test_immersiveWiringActivatesAndDeactivates() {
        compare(mainWindow.focusImmersiveActive, false)

        // 入口需要可投影状态：给 mock 一个进行中的自由会话。
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        const focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.immersiveRequested()
        compare(mainWindow.focusImmersiveActive, true)

        // 沉浸时主行隐藏（显式 false 断言不受祖先链影响，允许）。
        const row = findChild(mainWindow, "mainContentRow")
        verify(row)
        compare(row.visible, false)

        const overlay = findChild(mainWindow, "focusImmersiveOverlay")
        verify(overlay)
        overlay.exitRequested()
        compare(mainWindow.focusImmersiveActive, false)

        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
    }

    function test_focusEndedExitsImmersiveAndReturnsToday() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        const focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.immersiveRequested()
        compare(mainWindow.focusImmersiveActive, true)

        focusView.focusEnded()
        compare(mainWindow.focusImmersiveActive, false)
        compare(mainWindow.currentView, "today")

        focusTimer.hasActiveSession = false
        focusTimer.isRunning = false
    }

    function test_unprojectableAutoExitsViaOverlay() {
        focusTimer.hasActiveSession = true
        focusTimer.isRunning = true
        wait(20)

        const focusView = findChild(mainWindow, "focusViewPage")
        verify(focusView)
        focusView.immersiveRequested()
        compare(mainWindow.focusImmersiveActive, true)

        // 会话消失 → 自由态不可投影 → 沉浸层防御性退出应联动归零事实源。
        focusTimer.hasActiveSession = false
        wait(20)
        compare(mainWindow.focusImmersiveActive, false)

        focusTimer.isRunning = false
    }
```

- [ ] **Step 2: 跑测试确认失败。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: FAIL，`focusImmersiveActive` undefined / `mainContentRow`、`focusImmersiveOverlay` 找不到。

- [ ] **Step 3: 实现 MainWindow。** `qml/MainWindow.qml`：

3a. `property bool isSwitching: false` 之后加：

```qml
    // 全屏沉浸唯一事实源：窗口 visibility、主行显隐、沉浸层激活全部由它派生。
    property bool focusImmersiveActive: false
```

3b. `RowLayout { anchors.fill: parent` 处加 objectName 与 visible：

```qml
    RowLayout {
        objectName: "mainContentRow"

        anchors.fill: parent
        spacing: 0
        // 沉浸时整行隐藏，让沉浸层直接坐在壁纸上，避免侧栏透底。
        visible: !root.focusImmersiveActive
```

3c. `FocusView { id: focusView ... }` 声明里 `onFocusEnded` 替换为，并新增 `onImmersiveRequested`：

```qml
                    onFocusEnded: {
                        // 先退沉浸再切页：今日页不能卡在无侧栏的全屏里。
                        root.focusImmersiveActive = false;
                        root.switchToView("today");
                    }

                    onImmersiveRequested: root.focusImmersiveActive = true
```

3d. RowLayout 结束后、`Toast { id: globalToast ... }` 之前加（Toast 声明在后保持最顶，丢弃会话提示在退出沉浸后仍可见）：

```qml
    FocusImmersiveOverlay {
        id: focusImmersiveOverlay
        objectName: "focusImmersiveOverlay"

        anchors.fill: parent
        visible: root.focusImmersiveActive
        active: root.focusImmersiveActive
        focusViewRef: focusView
        timerRef: root.focusTimerRef
        settingsRef: root.appSettingsRef

        onExitRequested: root.focusImmersiveActive = false
    }
```

- [ ] **Step 4: 实现 main.qml。** `qml/main.qml`：

4a. `import "."` 之后加：

```qml
import "components"
```

4b. `MainWindow { id: mainContent ... }` 之后加：

```qml
    ImmersionWindowSync {
        id: immersionSync
    }

    // 沉浸开关 → 窗口 visibility；决策全部在 ImmersionWindowSync 里，可单测。
    Connections {
        target: mainContent

        function onFocusImmersiveActiveChanged() {
            root.visibility = immersionSync.visibilityForImmersiveChange(
                        mainContent.focusImmersiveActive, root.visibility);
        }
    }

    // 窗口侧变化（绿灯按钮/系统手势退出全屏）反向归零沉浸事实源。
    onVisibilityChanged: {
        if (!immersionSync.immersiveActiveAfterVisibilityChange(root.visibility, mainContent.focusImmersiveActive)
                && mainContent.focusImmersiveActive) {
            mainContent.focusImmersiveActive = false;
        }
    }
```

- [ ] **Step 5: 跑测试确认通过（全套）。**

Run: `ctest --test-dir build -R PomodoroTodoQmlTests --output-on-failure`
Expected: PASS，含 tst_mainwindow_ui_optimization 原有全部测试。

- [ ] **Step 6: 构建应用确认无 QML 加载错误。**

Run: `cmake --build build -j`
Expected: 构建成功。

- [ ] **Step 7: Commit。**

```bash
git add qml/MainWindow.qml qml/main.qml tests/qml/tst_mainwindow_ui_optimization.qml
git commit -m "主窗口与应用窗口接线全屏沉浸"
```

---

### Task 7: 全套回归 + 真机手动验证

**Files:**

- 无代码改动（若手动验证暴露问题，修复走独立小提交）

- [ ] **Step 1: 全部测试套件。**

Run: `ctest --test-dir build --output-on-failure`
Expected: 全部 PASS（含 C++ 服务测试）。

- [ ] **Step 2: 启动应用手动走查（macOS 真机，不可省略——窗口全屏行为 offscreen 测不到）。**

Run: `./build/PomodoroTodo`（若产物名不同，`ls build | grep -i pomodoro` 确认）

逐项核对：

1. 今日任务页选任务「开始专注」→ 专注页右上出现 ⛶（待机番茄页不出现）。
2. 点 ⛶ → 原生全屏（菜单栏/Dock 收起），只剩环/大数字 + 任务名，无侧栏透底。
3. 鼠标静止 3 秒 → 按钮与光标一起消失；移动鼠标 → 浮现。
4. 暂停 → 控制常驻不淡出；继续 → 恢复淡出节奏。
5. Esc → 退回原窗口尺寸；再进入后点 ✕ → 同样退出。
6. 番茄时长设为下限 5 分钟，沉浸中等工作段走完：完成后停留全屏、完成横幅 + 「开始休息」常驻 → 点「开始休息」继续沉浸进入休息段。
7. 沉浸中点「结束」→ 自动退出全屏并回到今日页。
8. 先绿灯按钮进原生全屏 → 点 ⛶ → 点 ✕：应保持全屏只收覆盖层。
9. 沉浸中用系统手势/绿灯退出全屏 → 沉浸层同步消失，主界面完好。
10. 最大化窗口进入沉浸 → Esc 退出 → 恢复最大化。
11. 设置开「减少动效」→ 控制显隐为直接切换无淡入淡出。

- [ ] **Step 3: 如手动验证全过，收尾确认工作树干净。**

Run: `git status --short`
Expected: 无未提交改动。

---

## 契约速查（跨任务命名，逐字一致）

| 名字 | 定义处 | 使用处 |
| --- | --- | --- |
| `immersiveRequested()` / `immersiveAvailable` / `endFreeFocus()` | Task 1 FocusView | Task 4 overlay、Task 6 MainWindow |
| `focusViewRef/timerRef/settingsRef/active` | Task 2 overlay | Task 6 MainWindow |
| `projectedState/completionState/sessionPaused/projectable` | Task 2 overlay | Task 3/4 |
| `controlsRevealed/controlsPinned/controlsShown/fadeAnimated/hideTimerRunning/revealControls()/hideControls()` | Task 3 overlay | Task 4 |
| `exitRequested()/requestExit()/triggerPrimary()/triggerSecondary()/primaryButtonText/primaryButtonEnabled/secondaryButtonText` | Task 4 overlay | Task 6 MainWindow |
| `preImmersiveVisibility/enteringFullScreen/visibilityForImmersiveChange()/immersiveActiveAfterVisibilityChange()` | Task 5 sync | Task 6 main.qml |
| `focusImmersiveActive` | Task 6 MainWindow | Task 6 main.qml |
