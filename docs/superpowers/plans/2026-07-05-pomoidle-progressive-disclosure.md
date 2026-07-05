# 番茄待机页渐进披露重设计 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** pomoIdle 态改为渐进披露：收起态只剩环+时长胶囊+开始按钮；点胶囊展开配置面板（chips 按值匹配 + 暖纸步进器取代 SpinBox 与"自定义"chip）；连带修正预览环、无任务指路、信息冗余。

**Architecture:** 全部改动集中在 `FocusView.qml`：新增 `panelExpanded` 状态属性驱动 胶囊/面板/环尺寸；删除 `workCustomSelected`/`breakCustomSelected`（chips 的 `checked` 纯按 `selectedWorkMinutes` 值匹配，步进器改出非预设值时 chips 自然全灭）；新增内联组件 `DurationStepper`。C++ 零改动。

**Tech Stack:** Qt 6.9 / Qt Quick(QML) / Qt Test。

**对应规格:** `docs/superpowers/specs/2026-07-05-pomoidle-progressive-disclosure-design.md`（视觉稿 `docs/superpowers/mockups/pomoidle-redesign.html`）。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；每个任务改完跑构建与相关测试再提交。
- 单文件 QML 测试：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml`；全量：`cmake --build build && ctest --test-dir build --output-on-failure`。
- 分支 `focus-ux-improvements`（已检出，勿切换）。
- **QML 测试纪律**：绝不断言 `something.visible === true`；断言驱动它的源头属性（`panelExpanded`、text、implicitWidth 等）。整套 QML 跑存在既有偶发失败（`tst_ui_optimization.qml`，与本计划无关），判定标准以单文件连跑 2 次全绿为准。
- 时长边界不变：专注 5–180、休息 1–60。文案用裸中文（不加 `qsTr()`）。
- **chips 必须 `checkable: false`**：Qt Quick 的可勾选按钮被点击时会命令式改写 `checked`，摧毁声明式绑定——之后步进器改值 chips 就不会跟着灭了。本计划 chips 的 `checked` 只作视觉态、纯绑定驱动，点击行为全部走 `onClicked` 调 `select*Minutes`。

---

### Task 1: panelExpanded 状态 + 时长胶囊 + 待机文案与无任务指路

**Files:**
- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Produces:
  - `property bool panelExpanded: false`（离开 pomoIdle 自动复位 false）
  - 胶囊按钮 objectName `durationPill`，文字 `专注 X 分 · 休息 Y 分 ▾/▴`，点击翻转 `panelExpanded`
  - 环心 caption Text 加 objectName `ringCaptionText`；pomoIdle 态文案改为 有任务`"准备开始"` / 无任务`"等待任务"`（原"专注 X 分 · 休息 Y 分"迁入胶囊）
  - 开始按钮下方微文案 Text objectName `noTaskHint`：无任务时 text 为 `"到今日任务里点「开始专注」即可带任务进入"`，有任务时为 `""`

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml` 的 `init()` 末尾（`wait(20)` 之前）加一行：

```qml
        view.panelExpanded = false
```

文件末尾新增四个测试：

```qml
    function test_durationPillShowsSelectionAndToggles() {
        view.toPomodoroTab(true)
        wait(20)

        const pill = findChild(view, "durationPill")
        verify(pill)
        verify(pill.contentItem.text.indexOf("专注 25 分 · 休息 5 分") !== -1)
        compare(view.panelExpanded, false)

        pill.clicked()
        compare(view.panelExpanded, true)
        pill.clicked()
        compare(view.panelExpanded, false)

        view.selectWorkMinutes(45)
        verify(pill.contentItem.text.indexOf("专注 45 分") !== -1)
    }

    function test_panelCollapsesWhenLeavingIdle() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        view.startPomodoro()
        wait(20)
        compare(view.state, "pomoWork")
        compare(view.panelExpanded, false)

        view.toPomodoroTab(true)
        view.panelExpanded = true
        view.toPomodoroTab(false)
        wait(20)
        compare(view.panelExpanded, false)
    }

    function test_idleCaptionReflectsTaskReadiness() {
        view.toPomodoroTab(true)
        wait(20)

        const caption = findChild(view, "ringCaptionText")
        verify(caption)
        compare(caption.text, "准备开始")

        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        view.pomoTaskId = -1
        wait(20)
        compare(caption.text, "等待任务")
    }

    function test_noTaskHintGuidesUser() {
        view.toPomodoroTab(true)
        wait(20)

        const hint = findChild(view, "noTaskHint")
        verify(hint)
        compare(hint.text, "")

        focusTimer.currentTaskId = -1
        focusTimer.currentTaskTitle = ""
        view.pomoTaskId = -1
        wait(20)
        compare(hint.text, "到今日任务里点「开始专注」即可带任务进入")
    }
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: 4 个新用例 FAIL（`panelExpanded`/`durationPill`/`ringCaptionText`/`noTaskHint` 不存在）。

- [x] **Step 3: 写实现**

`qml/views/FocusView.qml`：

属性区（`property int justCompletedPhase: 0` 之后、custom 两行之前）加：

```qml
    property bool panelExpanded: false
```

`state: root.computeState()` 之后加：

```qml
    onStateChanged: {
        // 离开待机态就收起配置面板：回到待机永远从干净的收起态开始，
        // 也顺带覆盖"成功启动专注后收起"（启动即离开 pomoIdle）。
        if (state !== "pomoIdle") {
            panelExpanded = false
        }
    }
```

`ringCaptionText()` 函数的 pomoIdle 分支改为（时长信息迁入胶囊，环心只说状态）：

```qml
        if (root.state === "pomoIdle") {
            return root.canStartPomodoro() ? "准备开始" : "等待任务"
        }
```

环心 caption Text（`text: root.ringCaptionText()` 那个）加一行 `objectName: "ringCaptionText"`。

FocusRing 实例之后、预设 GridLayout 之前加胶囊按钮：

```qml
            Button {
                id: durationPill
                objectName: "durationPill"
                Layout.alignment: Qt.AlignHCenter
                visible: root.state === "pomoIdle"
                implicitHeight: 36
                implicitWidth: pillLabel.implicitWidth + Theme.space24 * 2
                onClicked: root.panelExpanded = !root.panelExpanded

                background: Rectangle {
                    color: root.panelExpanded ? Theme.accentSoft : Theme.surfaceRaised
                    border.color: root.panelExpanded || durationPill.hovered ? Theme.accentStrong : Theme.border
                    border.width: 1
                    radius: height / 2
                }

                contentItem: Text {
                    id: pillLabel
                    text: "专注 " + root.selectedWorkMinutes + " 分 · 休息 " + root.selectedBreakMinutes + " 分  "
                          + (root.panelExpanded ? "▴" : "▾")
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
```

操作按钮 RowLayout（`pomodoroStopButton` 所在那个）之后加微文案：

```qml
            Text {
                objectName: "noTaskHint"
                Layout.fillWidth: true
                // 置灰的开始按钮必须解释原因，否则直接进专注页的用户会走进死路。
                text: root.state === "pomoIdle" && !root.canStartPomodoro()
                      ? "到今日任务里点「开始专注」即可带任务进入"
                      : ""
                visible: text.length > 0
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXs
                color: Theme.inkMuted
                horizontalAlignment: Text.AlignHCenter
            }
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS（此时旧预设网格仍在，属过渡状态，Task 2 移除）。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "番茄待机页新增时长胶囊与无任务指路"
```

---

### Task 2: 配置面板（chips 按值匹配 + 步进器）取代常驻网格

**Files:**
- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: Task 1 的 `panelExpanded`、`durationPill`
- Produces:
  - 内联组件 `DurationStepper`：属性 `value/from/to/namePrefix`，信号 `adjusted(int newValue)`；子项 objectName `namePrefix+"Minus"/"Value"/"Plus"`
  - 面板 Rectangle objectName `durationPanel`（`visible: pomoIdle && panelExpanded`）；chips 文字改裸数字，`checkable: false`，`checked` 纯按值匹配
  - 移除：`workCustomSelected`/`breakCustomSelected` 属性、两个"自定义"chip、SpinBox 行、两个 ButtonGroup、`Component.onCompleted` 里的 custom 判定
  - `ruleHintText` 改为仅 `pomoIdle && panelExpanded` 可见

- [x] **Step 1: 改写失败测试**

`tests/qml/tst_focus_view.qml`：

**删除** `test_customChipAndSpinBoxBounds` 和 `test_restoreCustomDurationSelectsCustomChip` 两个函数全文。

`init()` 中**删除**这两行（属性即将不存在）：

```qml
        view.workCustomSelected = false
        view.breakCustomSelected = false
```

`test_pomoIdleShowsRuleHint` 改为（规则说明只在展开面板时相关）：

```qml
    function test_pomoIdleShowsRuleHint() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const hint = findChild(view, "ruleHintText")
        verify(hint)
        compare(hint.text, "满 5 分钟自动完成任务 · 不足 3 分钟不计入记录")
        compare(view.state, "pomoIdle")
        compare(view.panelExpanded, true)
    }
```

文件末尾新增三个测试：

```qml
    function test_stepperAdjustsValueAndClampsAtBounds() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const plus = findChild(view, "workStepperPlus")
        const minus = findChild(view, "workStepperMinus")
        const valueText = findChild(view, "workStepperValue")
        verify(plus)
        verify(minus)
        verify(valueText)

        plus.clicked()
        compare(view.selectedWorkMinutes, 26)
        compare(appSettingsMock.workMinutes, 26)
        compare(valueText.text, "26")

        view.selectWorkMinutes(5)
        wait(20)
        compare(minus.enabled, false)
        view.selectWorkMinutes(180)
        wait(20)
        compare(plus.enabled, false)

        const breakPlus = findChild(view, "breakStepperPlus")
        const breakMinus = findChild(view, "breakStepperMinus")
        verify(breakPlus)
        verify(breakMinus)
        view.selectBreakMinutes(1)
        wait(20)
        compare(breakMinus.enabled, false)
        view.selectBreakMinutes(60)
        wait(20)
        compare(breakPlus.enabled, false)
    }

    function test_chipsMatchPurelyByValue() {
        view.toPomodoroTab(true)
        view.panelExpanded = true
        wait(20)

        const chip25 = findChild(view, "workPreset25")
        const chip45 = findChild(view, "workPreset45")
        const chip60 = findChild(view, "workPreset60")
        verify(chip25)
        compare(chip25.checked, true)

        // 步进到非预设值：chips 全灭，步进器本身就是"自定义"。
        view.selectWorkMinutes(90)
        wait(20)
        compare(chip25.checked, false)
        compare(chip45.checked, false)
        compare(chip60.checked, false)

        // 点 chip 回到预设：值与选中态同步恢复。
        chip45.clicked()
        wait(20)
        compare(view.selectedWorkMinutes, 45)
        compare(chip45.checked, true)
    }

    function test_restoreCustomDurationShowsInPillAndStepper() {
        var component = Qt.createComponent("../../qml/views/FocusView.qml")
        compare(component.status, Component.Ready)

        var restored = component.createObject(testCase, {
            timer: focusTimer,
            settings: customDurationSettingsMock
        })
        verify(restored)
        compare(restored.selectedWorkMinutes, 90)

        const pill = findChild(restored, "durationPill")
        verify(pill)
        verify(pill.contentItem.text.indexOf("专注 90 分 · 休息 5 分") !== -1)

        const chip25 = findChild(restored, "workPreset25")
        const chip45 = findChild(restored, "workPreset45")
        const chip60 = findChild(restored, "workPreset60")
        compare(chip25.checked, false)
        compare(chip45.checked, false)
        compare(chip60.checked, false)

        const valueText = findChild(restored, "workStepperValue")
        verify(valueText)
        compare(valueText.text, "90")
        restored.destroy()
    }
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: 新用例 FAIL（stepper 不存在、chips 仍受 `workCustomSelected` 影响、`init()` 引用已删属性会先报错——先删属性引用再看断言失败均可）。

- [x] **Step 3: 写实现**

`qml/views/FocusView.qml`：

**删除**属性两行：

```qml
    property bool workCustomSelected: false
    property bool breakCustomSelected: false
```

`Component.onCompleted` 收窄为（chips 按值自动匹配，无需 custom 判定）：

```qml
    Component.onCompleted: {
        // 恢复上次记住的时长；无效值会被 select 函数的范围校验挡掉，回落默认。
        if (root.settings) {
            root.selectWorkMinutes(Number(root.settings.workMinutes))
            root.selectBreakMinutes(Number(root.settings.breakMinutes))
        }
    }
```

`PresetButton` 组件定义之后新增步进器组件：

```qml
    // 暖纸步进器：面板里替代 SpinBox 与"自定义"chip。value 只读外部状态，
    // 加减通过 adjusted 信号回给 select*Minutes——保持 selectedWorkMinutes 单一数据源。
    component DurationStepper: RowLayout {
        id: stepper

        property int value: 0
        property int from: 1
        property int to: 99
        property string namePrefix: ""

        signal adjusted(int newValue)

        spacing: 0

        Button {
            objectName: stepper.namePrefix + "Minus"
            enabled: stepper.value > stepper.from
            implicitWidth: 32
            implicitHeight: 36
            onClicked: stepper.adjusted(stepper.value - 1)

            background: Rectangle {
                color: parent.enabled ? Theme.surface : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: "−"
                textFormat: Text.PlainText
                color: parent.parent.enabled ? Theme.inkSoft : Theme.inkMuted
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }

        Rectangle {
            implicitWidth: 52
            implicitHeight: 36
            color: Theme.surfaceSunken
            border.color: Theme.border
            border.width: 1

            Text {
                objectName: stepper.namePrefix + "Value"
                anchors.centerIn: parent
                text: stepper.value
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
            }
        }

        Button {
            objectName: stepper.namePrefix + "Plus"
            enabled: stepper.value < stepper.to
            implicitWidth: 32
            implicitHeight: 36
            onClicked: stepper.adjusted(stepper.value + 1)

            background: Rectangle {
                color: parent.enabled ? Theme.surface : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: "+"
                textFormat: Text.PlainText
                color: parent.parent.enabled ? Theme.inkSoft : Theme.inkMuted
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
```

**整体删除**：预设 `GridLayout {...}`（含两个 ButtonGroup、两个"自定义"chip、行尾占位 Item）与其后的 SpinBox `RowLayout {...}`，原位替换为面板：

```qml
            Rectangle {
                id: durationPanel
                objectName: "durationPanel"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(parent.width, 440)
                implicitHeight: panelColumn.implicitHeight + Theme.space16 * 2
                visible: root.state === "pomoIdle" && root.panelExpanded
                color: Theme.surfaceRaised
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusLg

                ColumnLayout {
                    id: panelColumn
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.space16
                    spacing: Theme.space8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8

                        Text {
                            text: "专注"
                            textFormat: Text.PlainText
                            color: Theme.inkSoft
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: 32
                        }

                        PresetButton {
                            objectName: "workPreset25"
                            text: "25"
                            backgroundObjectName: "workPreset25Background"
                            checkable: false
                            checked: root.selectedWorkMinutes === 25
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectWorkMinutes(25)
                        }

                        PresetButton {
                            objectName: "workPreset45"
                            text: "45"
                            backgroundObjectName: "workPreset45Background"
                            checkable: false
                            checked: root.selectedWorkMinutes === 45
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectWorkMinutes(45)
                        }

                        PresetButton {
                            objectName: "workPreset60"
                            text: "60"
                            backgroundObjectName: "workPreset60Background"
                            checkable: false
                            checked: root.selectedWorkMinutes === 60
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectWorkMinutes(60)
                        }

                        DurationStepper {
                            namePrefix: "workStepper"
                            value: root.selectedWorkMinutes
                            from: 5
                            to: 180
                            onAdjusted: function (newValue) {
                                root.selectWorkMinutes(newValue)
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space8

                        Text {
                            text: "休息"
                            textFormat: Text.PlainText
                            color: Theme.inkSoft
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: 32
                        }

                        PresetButton {
                            objectName: "breakPreset5"
                            text: "5"
                            backgroundObjectName: "breakPreset5Background"
                            checkable: false
                            checked: root.selectedBreakMinutes === 5
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectBreakMinutes(5)
                        }

                        PresetButton {
                            objectName: "breakPreset10"
                            text: "10"
                            backgroundObjectName: "breakPreset10Background"
                            checkable: false
                            checked: root.selectedBreakMinutes === 10
                            implicitWidth: 64
                            implicitHeight: 36
                            onClicked: root.selectBreakMinutes(10)
                        }

                        Item {
                            Layout.preferredWidth: 64 + Theme.space8
                        }

                        DurationStepper {
                            namePrefix: "breakStepper"
                            value: root.selectedBreakMinutes
                            from: 1
                            to: 60
                            onAdjusted: function (newValue) {
                                root.selectBreakMinutes(newValue)
                            }
                        }
                    }
                }
            }
```

`ruleHintText` 的 `visible` 改为：

```qml
                visible: root.state === "pomoIdle" && root.panelExpanded
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS，连跑 2 次稳定（既有 `test_switchToPomodoroShowsPresetsAndIdleState`、`test_presetButtonsUseWarmSelectedColor` 仍应通过——chips 还在，只是搬进了面板）。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "待机页配置面板渐进披露并用步进器取代自定义chip"
```

---

### Task 3: 预览环重绘 + 展开时环缩小

**Files:**
- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: Task 1 的 `panelExpanded`
- Produces: FocusRing 待机预览改为"极淡实心轨道 + 顶部 15° 强调弧"；`focusRing.implicitWidth` 收起 252 / 展开 190（150ms 动画）；环心时间字号 收起 56 / 展开 42。

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml` 文件末尾新增：

```qml
    function test_ringShrinksWhenPanelExpanded() {
        view.toPomodoroTab(true)
        wait(20)

        const ring = findChild(view, "focusRing")
        verify(ring)
        compare(ring.implicitWidth, 252)

        view.panelExpanded = true
        // implicitWidth 带 150ms 过渡动画，等它收敛到目标值。
        tryCompare(ring, "implicitWidth", 190, 1000)

        view.panelExpanded = false
        tryCompare(ring, "implicitWidth", 252, 1000)
    }
```

- [x] **Step 2: 运行测试确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（implicitWidth 恒为 252）。

- [x] **Step 3: 写实现**

`qml/views/FocusView.qml`：

FocusRing 组件 `onPaint` 的 `showPreview` 分支整体替换为：

```qml
            if (ring.showPreview) {
                // 预览＝极淡完整轨道：预告"进度环将画在这里"，
                // 比虚线更安静也不会碎成米粒。
                ctx.beginPath()
                ctx.setLineDash([])
                ctx.lineWidth = ring.strokeWidth
                ctx.strokeStyle = Theme.borderSubtle
                ctx.arc(centerX, centerY, radius, 0, Math.PI * 2, false)
                ctx.stroke()

                // 顶部约 15° 的强调弧：暗示进度从正上方开始画。
                ctx.beginPath()
                ctx.globalAlpha = 0.45
                ctx.strokeStyle = Theme.accent
                ctx.arc(centerX, centerY, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI / 12, false)
                ctx.stroke()
                ctx.globalAlpha = 1
                return
            }
```

focusRing 实例的尺寸改为（面板展开时让位）：

```qml
                implicitWidth: root.state === "pomoIdle" && root.panelExpanded ? 190 : 252
                implicitHeight: implicitWidth

                Behavior on implicitWidth {
                    NumberAnimation {
                        duration: 150
                        easing.type: Easing.OutQuad
                    }
                }
```

环心时间 Text 的字号改为：

```qml
                        font.pixelSize: root.state === "pomoIdle"
                                        ? (root.panelExpanded ? 42 : 56)
                                        : Theme.fontDisplay
```

- [x] **Step 4: qmllint + 运行测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS（`test_pomoIdleShowsRingPreview` 只断言 `showPreview` 属性，不受画法改变影响）。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "预览环改淡轨道强调弧并在面板展开时缩小让位"
```

---

### Task 4: 全量回归 + 真机冒烟

**Files:**
- 无新改动（验证任务；发现问题在此修复）

- [x] **Step 1: 全量构建与测试**

```bash
cmake --build build
ctest --test-dir build --output-on-failure
```

Expected: C++ 两套全绿；QML 整套若仅 `tst_ui_optimization.qml` 偶发失败，单文件重跑 `tst_focus_view.qml` 连续 2 次全绿即判定通过。

- [x] **Step 2: 真机冒烟**

```bash
open /Applications/番茄Todo.app
```

人工核对（对照视觉稿）：
1. 切到番茄：只见 环（淡轨道+顶部强调弧）+ 胶囊 + 开始按钮，无预设网格。
2. 点胶囊：面板展开、环缩小、规则说明出现；步进 +/− 改值 chips 跟随亮灭；再点胶囊收起。
3. 无任务进入：开始按钮置灰且下方出现指路文案。
4. 从今日任务直达（上次番茄模式）：胶囊显示记住的时长。
5. 启动专注：面板若展开会自动收起，进行态与原来一致。

- [x] **Step 3: 汇报结果**

冒烟通过后向用户汇报，等待确认是否合并回 `main`（不自行合并）。
