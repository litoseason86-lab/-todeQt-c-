# 减少动效门控 · 计划二 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让计划一存下的 `reduceMotion` 真正生效——门控 4 处循环/大位移动画（视图切换淡入淡出、侧栏状态●脉冲、完成横幅闪烁、统计数值 pulse），开启时改为瞬时。

**Architecture:** reduceMotion 来源按组件既有注入取——MainWindow 用 `appSettingsRef`、FocusView 用 `settings`、Sidebar/StatCard 用可注入的 `reduceMotionActive`（绑定默认走全局 `appSettings` 守卫，测试可直接赋值）。每处暴露驱动属性供断言。

**Tech Stack:** Qt 6.9 / QML / qmltestrunner

**Depends on:** 计划一已完成（`AppSettings.reduceMotion` 存在）。同在 `ui-polish` 分支。

## Global Constraints

- 注释、提交说明中文，解释为什么/边界。
- 自动流程无头，禁 `open`；QML `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`；验收 = 连续 2 次全绿。
- **断言驱动属性，不断言 `visible===true`、不断言视觉。**
- 门控范围仅这 4 处；专注环进度、70ms 微过渡、弹窗进出场**不动**。

---

### Task 1: Sidebar 状态脉冲门控

**Files:**

- Modify: `qml/components/Sidebar.qml`
- Test: `tests/qml/tst_sidebar_ui_optimization.qml`

**Interfaces:**

- Produces: Sidebar `property bool reduceMotionActive`（可注入）；statusPulse `readonly property bool pulseAnimationRunning`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_sidebar_ui_optimization.qml` 已有测试之后加（`focusTimerMock` 置运行中番茄令脉冲应转）：

```qml
    function test_pulseGatedByReduceMotion() {
        focusTimerMock.hasActiveSession = true
        focusTimerMock.isRunning = true
        focusTimerMock.mode = 1
        focusTimerMock.phase = 1
        focusTimerMock.remainingSeconds = 300
        wait(20)

        var pulse = findChild(sidebar, "sidebarStatusPulse-专")
        verify(pulse)
        sidebar.reduceMotionActive = false
        verify(pulse.pulseAnimationRunning === true, "常态下●应脉冲")

        sidebar.reduceMotionActive = true
        verify(pulse.pulseAnimationRunning === false, "减动效下●应停")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`
Expected: FAIL（`reduceMotionActive`/`pulseAnimationRunning` 未定义）。

- [ ] **Step 3: 实现**

`qml/components/Sidebar.qml` 根 Rectangle（`id: root`）属性区加可注入门控属性：

```qml
    // 减少动效：默认走全局 appSettings 守卫（生产存在、测试为 false），测试可直接赋值。
    // qmllint disable unqualified
    property bool reduceMotionActive:
        typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
    // qmllint enable unqualified
```

`statusPulse`（`id: statusPulse`）加暴露属性：

```qml
                    readonly property bool pulseAnimationRunning: pulseAnimation.running
```

`pulseAnimation` 的 `running` 加门控，并在停止时复位 opacity：

```qml
                    SequentialAnimation on opacity {
                        id: pulseAnimation

                        running: statusPulse.pulseRunning && !root.reduceMotionActive
                        loops: Animation.Infinite

                        // …… 两段 NumberAnimation 不动 ……

                        onRunningChanged: {
                            // 无论因失焦还是减动效停下，都把●复位到不透明，避免停在半透明帧。
                            if (!running) {
                                statusPulse.opacity = 1
                            }
                        }
                    }
```

原 `onPulseRunningChanged: { if (!pulseRunning) statusPulse.opacity = 1 }` 可保留（冗余但无害）或删除，二选一即可。

- [ ] **Step 4: 跑测试确认通过（2 次）+ lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_sidebar_ui_optimization.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/Sidebar.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/Sidebar.qml tests/qml/tst_sidebar_ui_optimization.qml
git commit -m "减动效门控：侧栏状态脉冲"
```

---

### Task 2: FocusView 完成横幅闪烁门控

**Files:**

- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**

- Consumes: `root.settings.reduceMotion`（FocusView 既有 `settings` 注入）。
- Produces: completionBanner `objectName: "focusCompletionBanner"` + `readonly property bool blinkRunning`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml` 已有测试之后加（`settings` 用既有 `appSettingsMock`，补 `reduceMotion` 属性；置 `state="workDone"` 令横幅可见）：

```qml
    function test_completionBlinkGatedByReduceMotion() {
        appSettingsMock.reduceMotion = false
        view.state = "workDone"
        wait(20)
        var banner = findChild(view, "focusCompletionBanner")
        verify(banner)
        verify(banner.blinkRunning === true, "常态下完成横幅应闪烁")

        appSettingsMock.reduceMotion = true
        verify(banner.blinkRunning === false, "减动效下完成横幅应停闪")
        view.state = "free"
    }
```

若 `appSettingsMock` 无 `reduceMotion` 属性，加 `property bool reduceMotion: false`。

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`
Expected: FAIL（objectName/blinkRunning 不存在）。

- [ ] **Step 3: 实现**

`qml/views/FocusView.qml` 的 completionBanner（`id: completionBanner`）加 objectName 与暴露属性，并把匿名 `OpacityAnimator on opacity` 提取为具名、加门控与停时复位：

```qml
            Rectangle {
                id: completionBanner
                objectName: "focusCompletionBanner"
                readonly property bool blinkRunning: completionBlink.running

                Layout.fillWidth: true
                Layout.preferredHeight: 44
                visible: root.state === "workDone" || root.state === "breakDone"
                opacity: visible ? 1 : 0
                color: Theme.accentSoft
                border.color: Theme.accent
                radius: Theme.radiusMd

                // …… 内部 Text 不动 ……

                OpacityAnimator on opacity {
                    id: completionBlink
                    from: 0.35
                    to: 1
                    duration: 520
                    loops: Animation.Infinite
                    running: completionBanner.visible && !(root.settings && root.settings.reduceMotion)

                    onRunningChanged: {
                        // 停闪时把 opacity 复位到可见值，避免停在 0.35 帧。
                        if (!running) {
                            completionBanner.opacity = completionBanner.visible ? 1 : 0
                        }
                    }
                }
            }
```

- [ ] **Step 4: 跑测试确认通过（2 次）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml`（×2）
Expected: 全绿 ×2。

- [ ] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "减动效门控：专注完成横幅闪烁"
```

---

### Task 3: StatCard 数值 pulse 门控

**Files:**

- Modify: `qml/components/StatCard.qml`
- Test: `tests/qml/tst_glass_components.qml`

**Interfaces:**

- Produces: StatCard 根 `property bool reduceMotionActive`（可注入）+ `readonly property bool valuePulseRunning`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_glass_components.qml` 已有测试之后加（实例 id `statCard`）：

```qml
    function test_valuePulseGatedByReduceMotion() {
        statCard.reduceMotionActive = false
        statCard.value = "1"
        wait(20)
        statCard.value = "2"
        verify(statCard.valuePulseRunning === true, "常态下数值变化应跳动")

        statCard.reduceMotionActive = true
        statCard.value = "3"
        verify(statCard.valuePulseRunning === false, "减动效下数值变化应不跳动")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_glass_components.qml`
Expected: FAIL（属性不存在）。

- [ ] **Step 3: 实现**

`qml/components/StatCard.qml` 根 Rectangle（`id: root`）属性区加：

```qml
    // qmllint disable unqualified
    property bool reduceMotionActive:
        typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
    // qmllint enable unqualified
    readonly property bool valuePulseRunning: valuePulse.running
```

`valueText` 的 `onTextChanged` 加门控：

```qml
                onTextChanged: {
                    if (!root.reduceMotionActive) {
                        valuePulse.restart()
                    }
                }
```

- [ ] **Step 4: 跑测试确认通过（2 次）+ lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_glass_components.qml`（×2）
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/StatCard.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/StatCard.qml tests/qml/tst_glass_components.qml
git commit -m "减动效门控：统计卡数值跳动"
```

---

### Task 4: MainWindow 视图切换瞬时分支

**Files:**

- Modify: `qml/MainWindow.qml`
- Test: `tests/qml/tst_mainwindow_ui_optimization.qml`

**Interfaces:**

- Consumes: `root.appSettingsRef.reduceMotion`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_mainwindow_ui_optimization.qml` 已有测试之后加（`appSettings` mock 补 `reduceMotion`）：

```qml
    function test_viewSwitchInstantUnderReduceMotion() {
        appSettings.reduceMotion = true
        mainWindow.switchToView("today")
        wait(20)
        mainWindow.switchToView("focus")
        // 瞬时分支：立即到位、无半切换态。
        compare(mainWindow.currentView, "focus")
        compare(mainWindow.isSwitching, false)
        var stack = findChild(mainWindow, "mainViewStack")
        verify(stack)
        compare(stack.opacity, 1.0)
        appSettings.reduceMotion = false
    }
```

若 `appSettings` mock 无 `reduceMotion`，加 `property bool reduceMotion: false`。

- [ ] **Step 2: 跑测试确认失败**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`
Expected: FAIL（走了淡入淡出，`isSwitching` 或 opacity 不满足即时值）。

- [ ] **Step 3: 实现——switchToView 重排**

`qml/MainWindow.qml` 的 `switchToView` 整体替换为（reduceMotion 瞬时分支必须在 `isSwitching` 早退之前）：

```qml
    function switchToView(viewName) {
        if (root.currentView === viewName && !root.isSwitching) {
            return;
        }

        // 减少动效：瞬时切换 + 完整复位，须在 isSwitching 早退之前，
        // 才能接住“动画中途开启减动效再切页”。
        if (root.appSettingsRef && root.appSettingsRef.reduceMotion) {
            viewFade.stop();
            root.currentView = viewName;
            root.pendingView = viewName;
            root.queuedView = "";
            root.isSwitching = false;
            stackLayout.opacity = 1.0;
            return;
        }

        if (root.isSwitching) {
            root.queuedView = viewName;
            return;
        }

        root.isSwitching = true;
        root.pendingView = viewName;
        root.queuedView = "";
        viewFade.restart();
    }
```

- [ ] **Step 4: 跑测试确认通过（2 次）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_mainwindow_ui_optimization.qml`（×2）
Expected: 全绿 ×2。

- [ ] **Step 5: 提交**

```bash
git add qml/MainWindow.qml tests/qml/tst_mainwindow_ui_optimization.qml
git commit -m "减动效门控：视图切换瞬时化"
```

---

### Task 5: 全量无头回归 + 人工验收

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量构建 + 四套测试**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 4/4 通过（tst_ui_optimization.qml 偶发按基线重跑一次区分）。

- [ ] **Step 2: 人工验收（仅此步用 open）**

Run: `open /Applications/番茄Todo.app`
在设置弹窗开"减少动效"，确认：切换视图无淡入淡出（瞬时）、侧栏专注状态●不再脉冲、专注完成横幅不闪、统计数值变化不跳动；关闭开关后以上动画恢复。汇报后等待确认是否合并 `ui-polish` 回 main（不自行合并）。
