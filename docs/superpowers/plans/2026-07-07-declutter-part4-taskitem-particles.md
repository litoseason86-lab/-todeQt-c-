# 拆臃肿 · 计划四（TaskItem 抽完成粒子组件）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans。纯重构：不改行为，既有测试是安全网（保持全绿）。Steps 用 `- [ ]` 追踪。

**Goal:** 把 TaskItem 的完成庆祝粒子系统抽成 `qml/components/CompletionParticles.qml`（暴露 `burst(originX, originY)` + `particleCount`），TaskItem 726 → ~670 行，行为与测试 100% 不变。

**Architecture:** 粒子的配置（颜色/方向数组）、容器 Item、粒子 Component 全部移进新组件；`completionAnimationPlayed` 守卫与"从 checkIndicator 中心迸发"的原点计算**留在 TaskItem**（它才知道 checkIndicator 位置），改为算好原点后调 `completionParticles.burst(x, y)`。objectName `completionParticleContainer`/`completionParticle` 原样保留，测试照常命中。CompletionParticles 与 TaskItem 同在 qml/components/，同目录隐式可用、无需 import。

**Tech Stack:** Qt 6.9 / QML / qmltestrunner

**Depends on:** 无。分支 `declutter-focusview-components`。

## Global Constraints

- 注释、提交说明中文，解释为什么/边界。
- 自动流程无头，禁 `open`；QML `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`；验收 = 连续 2 次全绿（该文件有既有 offscreen 偶发，偶发失败重跑一次区分，非本改动引入的须稳定绿）。
- **重构铁律：不改行为。** 粒子尺寸/travelDistance/动画时长/颜色/方向/objectName 全部逐字保留。
- CompletionParticles qmllint 零警告。

---

### Task 1: 创建 CompletionParticles.qml

**Files:**
- Create: `qml/components/CompletionParticles.qml`

**Interfaces:**
- Produces: `CompletionParticles` 组件——`function burst(originX, originY)`（在原点迸发 6 粒、已 `particleCount>0` 守卫）；`readonly property int particleCount`。objectName `completionParticleContainer`。

- [ ] **Step 1: 新建文件**

```qml
import QtQuick
import ".."

// 任务完成庆祝粒子：从给定原点向 6 个方向迸发的小圆点，各自飞出并淡出后自毁。
// 从 TaskItem 抽出，零外部状态依赖——调 burst(originX, originY) 触发；
// particleCount 供外部守卫与测试判断当前是否已在迸发。
Item {
    id: root

    objectName: "completionParticleContainer"
    enabled: false
    z: 20

    readonly property int particleCount: children.length

    // 配置随组件走（通用庆祝效果，不属 TaskItem 特有状态）。
    readonly property var particleColors: [Theme.accent, Theme.border, Theme.borderSubtle]
    readonly property var particleDirections: [[-1, -1], [-1, 0], [-1, 1], [1, -1], [1, 0], [1, 1]]

    function burst(originX, originY) {
        // 已在迸发中就不重复（与原 playCompletionAnimation 的 particleCount 守卫一致）。
        if (root.particleCount > 0) {
            return;
        }

        var travelDistance = 38;
        for (var i = 0; i < root.particleDirections.length; ++i) {
            var direction = root.particleDirections[i];
            var particle = particleComponent.createObject(root, {
                    "x": originX,
                    "y": originY,
                    "startX": originX,
                    "startY": originY,
                    "targetX": originX + direction[0] * travelDistance,
                    "targetY": originY + direction[1] * travelDistance,
                    "directionX": direction[0],
                    "directionY": direction[1],
                    "color": root.particleColors[i % root.particleColors.length]
                });

            if (particle === null) {
                console.warn("创建任务完成粒子失败");
            }
        }
    }

    Component {
        id: particleComponent

        Rectangle {
            id: particle

            objectName: "completionParticle"
            width: 5
            height: 5
            radius: width / 2
            opacity: 1
            property real startX: 0
            property real startY: 0
            property real targetX: 0
            property real targetY: 0
            property int directionX: 0
            property int directionY: 0

            SequentialAnimation {
                running: true

                ParallelAnimation {
                    NumberAnimation {
                        target: particle
                        property: "x"
                        to: particle.targetX
                        duration: 800
                        easing.type: Easing.OutQuad
                    }

                    NumberAnimation {
                        target: particle
                        property: "y"
                        to: particle.targetY
                        duration: 800
                        easing.type: Easing.OutQuad
                    }

                    OpacityAnimator {
                        target: particle
                        from: 1
                        to: 0
                        duration: 800
                        easing.type: Easing.OutQuad
                    }
                }

                onStopped: particle.destroy()
            }
        }
    }
}
```

- [ ] **Step 2: qmllint 零警告**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/CompletionParticles.qml`
Expected: 无输出。

---

### Task 2: qrc 注册 + TaskItem 切换到组件

**Files:**
- Modify: `resources/qml.qrc`
- Modify: `qml/components/TaskItem.qml`

**Interfaces:**
- Consumes: Task 1 的 CompletionParticles。

- [ ] **Step 1: qrc 注册**

在 `resources/qml.qrc` 组件区（`TaskItem.qml` 行附近）加：

```xml
        <file alias="qml/components/CompletionParticles.qml">../qml/components/CompletionParticles.qml</file>
```

- [ ] **Step 2: TaskItem 改造**

`qml/components/TaskItem.qml`：

1. 删除两个配置属性（约 47-48 行）：`readonly property var completionParticleColors: ...` 与 `readonly property var completionParticleDirections: ...`（已移进组件）。
2. 删除 `particleContainer` Item（约 267-275 行）与 `completionParticleComponent` Component（约 277-327 行）两整块。
3. 在原 `particleContainer` 位置放组件实例：

```qml
    CompletionParticles {
        id: completionParticles

        anchors.fill: parent
    }
```

4. `playCompletionAnimation()`（约 81-114 行）整函数替换为——守卫与原点计算留下，粒子创建交给 burst：

```qml
    function playCompletionAnimation() {
        if (root.completionAnimationPlayed)
            return;
        if (completionParticles.particleCount > 0)
            return;

        root.completionAnimationPlayed = true;

        // 原点＝复选框中心（5px 粒子居中偏移 2.5）；只有 TaskItem 知道 checkIndicator 位置。
        var indicatorPosition = checkIndicator.mapToItem(root, 0, 0);
        var startX = indicatorPosition.x + checkIndicator.width / 2 - 2.5;
        var startY = indicatorPosition.y + checkIndicator.height / 2 - 2.5;
        completionParticles.burst(startX, startY);
    }
```

（同目录隐式可用，TaskItem 无需加 import。）

- [ ] **Step 3: 构建**

Run: `cmake --build build 2>&1 | tail -3`
Expected: 通过。若报 `CompletionParticles is not a type`，确认 qrc 已注册且文件在 qml/components/。

- [ ] **Step 4: 测试 ×2 + lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`（×2）
Expected: 全绿 ×2（`completionParticleContainer`/`completionParticle`/`particleCount` 相关断言不变；偶发按基线重跑区分）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/TaskItem.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/CompletionParticles.qml qml/components/TaskItem.qml resources/qml.qrc
git commit -m "TaskItem 抽出完成庆祝粒子为独立组件"
```

---

### Task 3: 全量无头回归 + #5 收官

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量回归**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 4/4 通过（SettingsDialog 偶发布局用例按既有基线重跑区分，非本改动）。`wc -l qml/components/TaskItem.qml` ≈ 670。

- [ ] **Step 2: 汇报 #5 成果**

汇报四文件最终行数（FocusView 993 / StatisticsView 856 / MonthGoalView 592 / TaskItem ~670）与全绿，说明 monthCalendarContainer 按 ROI 判断刻意跳过（MonthGoalView 已 592、其耦合重风险高），等待用户确认是否合并 `declutter-focusview-components` 回 main。
