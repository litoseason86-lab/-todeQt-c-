# 专注 UX 改进第三部分：规则透明化 + 提示音 + 自定义时长 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 番茄待机态展示 3/5 分钟规则说明；阶段完成播放可关闭的提示音；专注/休息时长支持自定义（5–180 / 1–60 分）并与记忆机制统一。

**Architecture:** `FocusTimer` 暴露两个 CONSTANT 属性作为规则文案的数据源；提示音走 `QtMultimedia SoundEffect` + 合成 wav 资源，开关存 AppSettings；自定义时长用「自定义」chip + 内联 SpinBox，`select*Minutes` 白名单改范围校验，持久化沿用第一部分的分钟数键。

**Tech Stack:** Qt 6.9 / C++17 / Qt Quick(QML) / QtMultimedia / Qt Test / CMake。

**对应规格:** `docs/superpowers/specs/2026-07-05-focus-ux-improvements-design.md` 的「⑥⑦⑧」。

**前置依赖:** 第一部分（`settings` 注入、写回、恢复）与第二部分已合入。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；每个任务改完跑构建与相关测试再提交。
- 配置：`cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos`；构建：`cmake --build build`；C++ 测试：`ctest --test-dir build -R PomodoroTodoTests --output-on-failure`；单文件 QML：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<file>.qml`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`。
- 分支 `focus-ux-improvements`。
- **QML 测试纪律**：绝不断言 `something.visible === true`；断言驱动它的源头属性。
- 时长边界：专注 5–180 分、休息 1–60 分。
- 文案用裸中文（不加 `qsTr()`）。

---

### Task 1: FocusTimer 暴露规则常量（C++）

**Files:**
- Modify: `src/services/FocusTimer.h`
- Modify: `src/services/FocusTimer.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces: `Q_PROPERTY int minimumValidMinutes`（=3，CONSTANT）、`Q_PROPERTY int autoCompleteMinutes`（=5，CONSTANT），数据源 `FocusSessionRules.h`。

- [x] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` 的 `private slots:` 区加：

```cpp
    void focusTimerExposesRuleConstants();
```

实现区加：

```cpp
void ServiceTests::focusTimerExposesRuleConstants()
{
    FocusTimer* timer = FocusTimer::instance();
    QCOMPARE(timer->minimumValidMinutes(), 3);
    QCOMPARE(timer->autoCompleteMinutes(), 5);
}
```

- [x] **Step 2: 运行确认编译失败**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误（成员不存在）。

- [x] **Step 3: 写实现**

`src/services/FocusTimer.h`：Q_PROPERTY 区（`remainingSeconds` 之后）加：

```cpp
    Q_PROPERTY(int minimumValidMinutes READ minimumValidMinutes CONSTANT)
    Q_PROPERTY(int autoCompleteMinutes READ autoCompleteMinutes CONSTANT)
```

public 函数声明区（`remainingSeconds()` 之后）加：

```cpp
    int minimumValidMinutes() const;
    int autoCompleteMinutes() const;
```

`src/services/FocusTimer.cpp`（`remainingSeconds()` 实现之后）加：

```cpp
int FocusTimer::minimumValidMinutes() const
{
    // 界面规则文案的数据源；换算自秒级常量，规则改动时文案自动跟随。
    return FocusSessionRules::kMinimumValidDurationSeconds / 60;
}

int FocusTimer::autoCompleteMinutes() const
{
    return FocusSessionRules::kAutoCompleteTaskDurationSeconds / 60;
}
```

- [x] **Step 4: 运行测试确认通过**

Run: `cmake --build build && ctest --test-dir build -R PomodoroTodoTests --output-on-failure`
Expected: PASS。

- [x] **Step 5: 提交**

```bash
git add src/services/FocusTimer.h src/services/FocusTimer.cpp tests/ServiceTests.cpp
git commit -m "FocusTimer 暴露最短有效与自动完成分钟常量"
```

---

### Task 2: 番茄待机态规则说明文字（QML）

**Files:**
- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: Task 1 的 `minimumValidMinutes`/`autoCompleteMinutes`（经 `root.timerNumber` 带默认值读取，mock 缺属性也能工作）
- Produces: objectName `"ruleHintText"` 的 Text，仅 `pomoIdle` 态显示。

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml` 的 focusTimer mock 属性区加：

```qml
        property int minimumValidMinutes: 3
        property int autoCompleteMinutes: 5
```

新增测试：

```qml
    function test_pomoIdleShowsRuleHint() {
        view.toPomodoroTab(true)
        wait(20)

        const hint = findChild(view, "ruleHintText")
        verify(hint)
        compare(hint.text, "满 5 分钟自动完成任务 · 不足 3 分钟不计入记录")
        compare(view.state, "pomoIdle")
    }
```

- [x] **Step 2: 运行确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（`ruleHintText` 不存在）。

- [x] **Step 3: 写实现**

`qml/views/FocusView.qml`：预设 GridLayout 之后（errorText 的 Text 之前）加：

```qml
            Text {
                objectName: "ruleHintText"
                Layout.fillWidth: true
                visible: root.state === "pomoIdle"
                text: "满 " + root.timerNumber("autoCompleteMinutes", 5) + " 分钟自动完成任务 · 不足 "
                      + root.timerNumber("minimumValidMinutes", 3) + " 分钟不计入记录"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkMuted
                horizontalAlignment: Text.AlignHCenter
            }
```

- [x] **Step 4: qmllint + 运行确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "番茄待机态展示自动完成与最短记录规则"
```

---

### Task 3: 自定义时长（chip + SpinBox + 范围校验 + 恢复）

**Files:**
- Modify: `qml/views/FocusView.qml`
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: 第一部分的 `settings` 注入与 `Component.onCompleted` 恢复
- Produces:
  - `property bool workCustomSelected` / `property bool breakCustomSelected`
  - chips objectName：`workPresetCustom` / `breakPresetCustom`
  - SpinBox objectName：`workCustomSpinBox`（from 5, to 180）/ `breakCustomSpinBox`（from 1, to 60）
  - `selectWorkMinutes` 接受 5–180、`selectBreakMinutes` 接受 1–60（取代白名单）

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_view.qml` 的 `init()` 中重置区加：

```qml
        view.workCustomSelected = false
        view.breakCustomSelected = false
```

新增测试：

```qml
    function test_selectMinutesAcceptsRangeAndRejectsOutOfBounds() {
        view.toPomodoroTab(true)

        view.selectWorkMinutes(90)
        compare(view.selectedWorkMinutes, 90)
        compare(appSettingsMock.workMinutes, 90)

        view.selectWorkMinutes(4)     // 低于下限拒绝
        compare(view.selectedWorkMinutes, 90)
        view.selectWorkMinutes(181)   // 高于上限拒绝
        compare(view.selectedWorkMinutes, 90)

        view.selectBreakMinutes(1)
        compare(view.selectedBreakMinutes, 1)
        view.selectBreakMinutes(0)
        compare(view.selectedBreakMinutes, 1)
        view.selectBreakMinutes(61)
        compare(view.selectedBreakMinutes, 1)
    }

    function test_customChipAndSpinBoxBounds() {
        view.toPomodoroTab(true)
        view.workCustomSelected = true
        view.breakCustomSelected = true
        wait(20)

        const workSpin = findChild(view, "workCustomSpinBox")
        const breakSpin = findChild(view, "breakCustomSpinBox")
        verify(workSpin)
        verify(breakSpin)
        compare(workSpin.from, 5)
        compare(workSpin.to, 180)
        compare(breakSpin.from, 1)
        compare(breakSpin.to, 60)

        const workChip = findChild(view, "workPresetCustom")
        verify(workChip)
        compare(workChip.checked, true)
    }

    function test_restoreCustomDurationSelectsCustomChip() {
        var component = Qt.createComponent("../../qml/views/FocusView.qml")
        compare(component.status, Component.Ready)

        var restored = component.createObject(testCase, {
            timer: focusTimer,
            settings: customDurationSettingsMock
        })
        verify(restored)
        compare(restored.selectedWorkMinutes, 90)
        compare(restored.workCustomSelected, true)
        compare(restored.breakCustomSelected, false)

        const chip = findChild(restored, "workPresetCustom")
        verify(chip)
        compare(chip.text, "90 分")
        restored.destroy()
    }
```

mock 区加：

```qml
    QtObject {
        id: customDurationSettingsMock

        property int lastMode: 1
        property int workMinutes: 90
        property int breakMinutes: 5
        property bool soundEnabled: true
    }
```

- [x] **Step 2: 运行确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（90 被白名单拒绝、chip/SpinBox 不存在）。

- [x] **Step 3: 写实现**

`qml/views/FocusView.qml`：

属性区加：

```qml
    property bool workCustomSelected: false
    property bool breakCustomSelected: false
```

`selectWorkMinutes`/`selectBreakMinutes` 改为范围校验（写回逻辑保留）：

```qml
    function selectWorkMinutes(minutes) {
        var value = Math.round(Number(minutes))
        // 范围而非白名单：自定义时长（如 90 分）也走同一入口，持久化才能统一。
        if (value >= 5 && value <= 180) {
            root.selectedWorkMinutes = value
            if (root.settings) {
                root.settings.workMinutes = value
            }
        }
    }

    function selectBreakMinutes(minutes) {
        var value = Math.round(Number(minutes))
        if (value >= 1 && value <= 60) {
            root.selectedBreakMinutes = value
            if (root.settings) {
                root.settings.breakMinutes = value
            }
        }
    }
```

`Component.onCompleted` 改为（恢复后判定是否命中预设）：

```qml
    Component.onCompleted: {
        if (root.settings) {
            root.selectWorkMinutes(Number(root.settings.workMinutes))
            root.selectBreakMinutes(Number(root.settings.breakMinutes))
        }
        // 恢复的值不在预设里 → 自动落到"自定义"chip，并把值显示在 chip 上。
        root.workCustomSelected = root.selectedWorkMinutes !== 25
                && root.selectedWorkMinutes !== 45
                && root.selectedWorkMinutes !== 60
        root.breakCustomSelected = root.selectedBreakMinutes !== 5
                && root.selectedBreakMinutes !== 10
    }
```

预设 GridLayout：`columns: 4` 改 `columns: 5`。三个专注预设的 `checked` 各改为叠加非自定义条件、`onClicked` 各加取消自定义（三个都要改，示例 25 分，45/60 同形）：

```qml
                PresetButton {
                    id: workPreset25
                    objectName: "workPreset25"
                    text: "25 分"
                    backgroundObjectName: "workPreset25Background"
                    checked: !root.workCustomSelected && root.selectedWorkMinutes === 25

                    ButtonGroup.group: workPresetGroup

                    onClicked: {
                        root.workCustomSelected = false
                        root.selectWorkMinutes(25)
                    }
                }
```

专注行 `workPreset60` 之后加自定义 chip：

```qml
                PresetButton {
                    id: workPresetCustom
                    objectName: "workPresetCustom"
                    text: root.workCustomSelected ? root.selectedWorkMinutes + " 分" : "自定义"
                    backgroundObjectName: "workPresetCustomBackground"
                    checked: root.workCustomSelected

                    ButtonGroup.group: workPresetGroup

                    onClicked: root.workCustomSelected = true
                }
```

休息行两个预设同样改造（`checked: !root.breakCustomSelected && root.selectedBreakMinutes === 5`，onClicked 先 `root.breakCustomSelected = false`）；删除行尾占位 `Item`，`breakPreset10` 之后加：

```qml
                PresetButton {
                    id: breakPresetCustom
                    objectName: "breakPresetCustom"
                    text: root.breakCustomSelected ? root.selectedBreakMinutes + " 分" : "自定义"
                    backgroundObjectName: "breakPresetCustomBackground"
                    checked: root.breakCustomSelected

                    ButtonGroup.group: breakPresetGroup

                    onClicked: root.breakCustomSelected = true
                }

                Item {
                    Layout.preferredWidth: 104
                    Layout.preferredHeight: 42
                }
```

GridLayout 之后、规则说明 Text 之前加内联 SpinBox 行：

```qml
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                visible: root.state === "pomoIdle" && (root.workCustomSelected || root.breakCustomSelected)
                spacing: Theme.space16

                RowLayout {
                    visible: root.workCustomSelected
                    spacing: Theme.space4

                    Text {
                        text: "专注(分)"
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }

                    SpinBox {
                        id: workCustomSpinBox
                        objectName: "workCustomSpinBox"
                        from: 5
                        to: 180
                        editable: true
                        value: root.selectedWorkMinutes
                        onValueModified: root.selectWorkMinutes(value)
                    }
                }

                RowLayout {
                    visible: root.breakCustomSelected
                    spacing: Theme.space4

                    Text {
                        text: "休息(分)"
                        textFormat: Text.PlainText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }

                    SpinBox {
                        id: breakCustomSpinBox
                        objectName: "breakCustomSpinBox"
                        from: 1
                        to: 60
                        editable: true
                        value: root.selectedBreakMinutes
                        onValueModified: root.selectBreakMinutes(value)
                    }
                }
            }
```

- [x] **Step 4: qmllint + 运行确认通过（含既有用例回归）**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/FocusView.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS（既有 `test_presetButtonsUseWarmSelectedColor` 等不受影响），连跑 2 次稳定。

- [x] **Step 5: 提交**

```bash
git add qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "番茄时长支持自定义并与记忆机制统一"
```

---

### Task 4: 阶段完成提示音 + 声音开关

**Files:**
- Create: `resources/sounds/phase-complete.wav`（脚本合成）
- Modify: `CMakeLists.txt`（Multimedia 组件）
- Modify: `resources/qml.qrc`（注册 wav）
- Modify: `qml/main.qml`（SoundEffect + 播放）
- Modify: `qml/views/FocusView.qml`（声音开关按钮）
- Test: `tests/qml/tst_focus_view.qml`

**Interfaces:**
- Consumes: 第一部分的 `appSettings.soundEnabled`、FocusView 的 `settings`
- Produces: FocusView 右上角开关按钮 objectName `"soundToggleButton"`，点击翻转 `settings.soundEnabled`；main.qml 阶段完成按开关播放 chime。

- [x] **Step 1: 合成音源**

```bash
mkdir -p resources/sounds
python3 - <<'EOF'
import math, struct, wave

# 双音上行 chime（A5→D6），首尾各带短淡入淡出，总时长约 0.6 秒。
sr = 44100
def tone(freq, dur, amp=0.35):
    n = int(sr * dur)
    out = []
    for t in range(n):
        env = min(1.0, t / (sr * 0.01), (n - t) / (sr * 0.12))
        out.append(amp * env * math.sin(2 * math.pi * freq * t / sr))
    return out

samples = tone(880.0, 0.28) + tone(1174.66, 0.34)
with wave.open("resources/sounds/phase-complete.wav", "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(b"".join(
        struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))
print("written")
EOF
```

Expected: 输出 `written`，文件约 50KB。

- [x] **Step 2: 写失败测试（开关按钮）**

`tests/qml/tst_focus_view.qml` 新增：

```qml
    function test_soundToggleFlipsSetting() {
        appSettingsMock.soundEnabled = true

        const toggle = findChild(view, "soundToggleButton")
        verify(toggle)
        toggle.clicked()
        compare(appSettingsMock.soundEnabled, false)
        toggle.clicked()
        compare(appSettingsMock.soundEnabled, true)
    }
```

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（按钮不存在）。

- [x] **Step 3: 写实现**

`CMakeLists.txt`：`find_package` 行的 COMPONENTS 加 `Multimedia`；`target_link_libraries(PomodoroTodo ...)` 加 `Qt6::Multimedia`（测试目标不需要）。

`resources/qml.qrc` 加：

```xml
        <file alias="sounds/phase-complete.wav">sounds/phase-complete.wav</file>
```

`qml/main.qml`：import 区加 `import QtMultimedia`；ApplicationWindow 内加：

```qml
    SoundEffect {
        id: phaseChime

        source: "qrc:/sounds/phase-complete.wav"
    }
```

`onPhaseCompleted` 改为：

```qml
        function onPhaseCompleted(phase) {
            root.raise();
            root.requestActivate();
            // 提示音默认开、可在专注页关闭；appSettings 缺失时按默认开处理。
            // qmllint disable unqualified
            if (typeof appSettings === "undefined" || !appSettings || appSettings.soundEnabled) {
                phaseChime.play();
            }
            // qmllint enable unqualified
        }
```

`qml/views/FocusView.qml`：背景 Rectangle 内、ColumnLayout 之后加开关按钮（所有状态可见）：

```qml
        Button {
            id: soundToggleButton
            objectName: "soundToggleButton"

            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Theme.space16
            implicitWidth: 40
            implicitHeight: 32
            onClicked: {
                if (root.settings) {
                    root.settings.soundEnabled = !root.settings.soundEnabled
                }
            }

            background: Rectangle {
                color: soundToggleButton.hovered ? Theme.surface : "transparent"
                border.color: soundToggleButton.hovered ? Theme.border : "transparent"
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: root.settings && root.settings.soundEnabled ? "🔔" : "🔕"
                font.pixelSize: Theme.fontLg
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
```

- [x] **Step 4: 重新配置 + 构建 + 测试**

Run:
```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos
cmake --build build
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/main.qml qml/views/FocusView.qml
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_view.qml 2>/dev/null | grep -E "FAIL|Totals"
ctest --test-dir build --output-on-failure
```
Expected: 配置成功（Multimedia 找到）；构建成功；lint 无输出；测试全绿。

- [x] **Step 5: 真机冒烟**

```bash
open /Applications/番茄Todo.app
```

人工验证：番茄 1 分钟自定义时长 → 到点听到 chime、窗口置前；点 🔕 后再来一轮 → 无声。

- [x] **Step 6: 提交**

```bash
git add resources/sounds/phase-complete.wav resources/qml.qrc CMakeLists.txt qml/main.qml qml/views/FocusView.qml tests/qml/tst_focus_view.qml
git commit -m "阶段完成播放提示音并支持专注页开关"
```
