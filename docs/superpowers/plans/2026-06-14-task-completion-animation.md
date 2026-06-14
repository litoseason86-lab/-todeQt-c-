# 任务完成动画增强实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为任务完成添加微粒子庆祝动画，从checkbox散发温暖色系圆点，营造仪式感

**Architecture:** 在TaskItem中添加粒子容器和Component定义，动态创建粒子Rectangle，使用SequentialAnimation控制飞散和淡出，完成后销毁

**Tech Stack:** QML, SequentialAnimation, ParallelAnimation, OpacityAnimator, Component.createObject

---

## Task 1: 创建粒子组件定义

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 在TaskItem根元素内添加粒子Component定义**

在TaskItem的Rectangle根元素内部（任何子元素之前），添加Component定义：

```qml
Rectangle {
    id: root
    
    // ... 现有属性 ...
    
    // 新增：粒子组件定义
    Component {
        id: particleComponent
        
        Rectangle {
            id: particle
            width: 5
            height: 5
            radius: 2.5
            opacity: 1.0
            z: 20
            
            property real targetX: 0
            property real targetY: 0
            
            SequentialAnimation {
                id: flyAnimation
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
                        from: 1.0
                        to: 0.0
                        duration: 800
                        easing.type: Easing.OutQuad
                    }
                }
                
                ScriptAction {
                    script: particle.destroy()
                }
            }
        }
    }
```

- [ ] **Step 2: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功，QML无语法错误

- [ ] **Step 3: 提交粒子组件定义**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(task): add particle component definition

- Create Component for dynamic particle creation
- Define Rectangle with circular shape (5px, radius 2.5)
- Implement fly animation: translate + opacity fade
- Auto-destroy particle after animation completes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 2: 添加粒子容器

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 在TaskItem根元素内添加粒子容器Item**

在particleComponent定义之后，现有的content区域之前，添加：

```qml
    // 新增：粒子容器
    Item {
        id: particleContainer
        anchors.fill: parent
        z: 10
    }
```

- [ ] **Step 2: 验证编译和运行**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
./build/TomatoTodo
```

预期结果：

- 应用启动成功
- 任务列表正常显示
- 粒子容器不可见（因为还没有创建粒子）

- [ ] **Step 3: 提交粒子容器**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(task): add particle container

- Add Item as container for dynamically created particles
- Position over entire task card with z: 10
- Prepare for particle spawning on completion

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 3: 实现粒子动画触发函数

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 在TaskItem中添加playCompletionAnimation函数声明**

在TaskItem的function区域添加：

```qml
    function playCompletionAnimation() {
        // 实现将在后续步骤补充
    }
```

- [ ] **Step 2: 实现checkbox中心点坐标计算**

在playCompletionAnimation函数内添加：

```qml
    function playCompletionAnimation() {
        // 计算checkbox的中心点坐标
        var checkboxItem = content.children[0]  // 假设checkbox是第一个子元素
        if (!checkboxItem) return
        
        var checkboxRect = checkboxItem.mapToItem(root, 0, 0)
        var centerX = checkboxRect.x + checkboxItem.width / 2
        var centerY = checkboxRect.y + checkboxItem.height / 2
    }
```

- [ ] **Step 3: 定义粒子颜色和飞行方向**

在centerY计算之后添加：

```qml
        // 温暖色系颜色数组
        var colors = ["#d4a574", "#e8dfc8", "#f0e6d2"]
        
        // 6个方向的飞行向量
        var directions = [
            {dx: -35, dy: -35},  // 左上
            {dx: -40, dy: 0},    // 左
            {dx: -35, dy: 35},   // 左下
            {dx: 35, dy: -35},   // 右上
            {dx: 40, dy: 0},     // 右
            {dx: 35, dy: 35}     // 右下
        ]
```

- [ ] **Step 4: 循环创建6个粒子**

在directions定义之后添加：

```qml
        // 创建6个粒子
        for (var i = 0; i < 6; i++) {
            var particle = particleComponent.createObject(particleContainer, {
                x: centerX,
                y: centerY,
                color: colors[i % 3],
                targetX: centerX + directions[i].dx,
                targetY: centerY + directions[i].dy
            })
        }
```

- [ ] **Step 5: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 6: 提交粒子触发函数**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(task): implement playCompletionAnimation function

- Calculate checkbox center point coordinates
- Define 3 warm colors and 6 flight directions
- Dynamically create 6 particles with Component.createObject
- Each particle flies in radial pattern from center

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 4: 连接到checkbox的完成事件

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 找到TaskItem的states定义区域**

定位到现有的State定义（normal和completed状态）

- [ ] **Step 2: 在completed状态中添加StateChangeScript**

在completed状态的PropertyChanges之后添加：

```qml
    State {
        name: "completed"
        when: root.taskCompleted
        
        PropertyChanges {
            root.opacity: 0.70
            root.completionOffset: 5
        }
        
        // 新增：状态进入时触发粒子动画
        StateChangeScript {
            script: root.playCompletionAnimation()
        }
    }
```

- [ ] **Step 3: 验证编译和运行**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
./build/TomatoTodo
```

预期结果：

- 应用启动成功
- 打开今日任务页面
- 勾选任何任务的checkbox
- 应该看到6个小圆点从checkbox飞散
- 圆点在飞行中逐渐淡出
- 任务卡片同时淡化为半透明

- [ ] **Step 4: 提交checkbox连接**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(task): connect particle animation to completion

- Trigger playCompletionAnimation in completed state
- Use StateChangeScript for state entry action
- Particle animation plays when task is marked complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 5: 添加防重复触发机制

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 添加animationPlayed标记属性**

在TaskItem的property声明区域添加：

```qml
    property bool animationPlayed: false
```

- [ ] **Step 2: 修改StateChangeScript添加防重复逻辑**

修改completed状态的StateChangeScript：

```qml
        StateChangeScript {
            script: {
                if (!root.animationPlayed) {
                    root.playCompletionAnimation()
                    root.animationPlayed = true
                }
            }
        }
```

- [ ] **Step 3: 添加taskCompleted变化监听以重置标记**

在TaskItem的Connections或property区域添加：

```qml
    onTaskCompletedChanged: {
        if (!taskCompleted) {
            animationPlayed = false
        }
    }
```

- [ ] **Step 4: 验证编译和运行**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
./build/TomatoTodo
```

测试场景：

1. 勾选任务 → 粒子动画播放
2. 取消勾选 → 卡片恢复，标记重置
3. 再次勾选 → 粒子动画再次播放
4. 多次勾选/取消 → 动画不会重复触发

- [ ] **Step 5: 提交防重复机制**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(task): add animation replay prevention

- Add animationPlayed flag to prevent duplicate triggers
- Reset flag when task is unchecked
- Ensure animation plays once per completion

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 6: 完整功能测试和提交

**Files:**
- All modified files

- [ ] **Step 1: 基础功能测试**

```bash
./build/TomatoTodo
```

测试清单：

1. 打开今日任务页面
2. 勾选一个任务
3. 确认：6个彩色圆点从checkbox飞散
4. 确认：粒子向6个方向均匀散开
5. 确认：粒子在800ms内淡出并消失
6. 确认：任务卡片同时淡化为半透明

- [ ] **Step 2: 粒子视觉测试**

测试清单：

1. 粒子颜色：金色、浅米色、极浅米色三种交替
2. 粒子大小：5px圆形，清晰可见
3. 飞行距离：约35-40px，不会太远或太近
4. 粒子层级：在卡片内容之上，不被遮挡
5. 粒子不溢出应用窗口边界

- [ ] **Step 3: 性能测试**

测试清单：

1. 连续快速完成5个任务
2. 确认：所有动画流畅，无卡顿
3. 确认：粒子对象被正确销毁（无内存泄漏迹象）
4. 使用任务管理器观察内存占用稳定

- [ ] **Step 4: 边界情况测试**

测试清单：

1. 勾选任务后立即取消勾选 → 动画继续播放完成
2. 快速多次勾选/取消同一任务 → 不会创建多余粒子
3. 列表中第一个和最后一个任务 → 粒子不溢出
4. 窗口缩小到最小尺寸 → 粒子仍正常显示

- [ ] **Step 5: 与现有动画协调测试**

测试清单：

1. 粒子动画不影响卡片淡化动画
2. 粒子动画不影响completionOffset位移
3. 粒子动画不影响文字删除线
4. 所有动画时序协调一致

- [ ] **Step 6: 最终代码检查**

```bash
git diff qml/components/TaskItem.qml
```

确认：

- particleComponent定义完整
- particleContainer正确放置
- playCompletionAnimation函数逻辑正确
- 防重复机制正常工作
- 无调试代码遗留

- [ ] **Step 7: 最终提交**

```bash
git add qml/components/TaskItem.qml

git commit -m "feat(task): complete particle celebration animation

Implemented particle animation for task completion:
- Component-based dynamic particle creation
- 6 particles in warm colors (#d4a574, #e8dfc8, #f0e6d2)
- Radial flight pattern with fade-out
- Auto-destroy after 800ms animation
- Prevent duplicate triggers with animationPlayed flag

Animation details:
- Particle size: 5px circular
- Flight distance: 35-40px in 6 directions
- Easing: OutQuad for smooth deceleration
- Coordinated with existing completion state animation

Tested:
- Visual effect: particles visible and natural
- Performance: smooth with multiple rapid completions
- Edge cases: no duplicate triggers, proper cleanup
- Integration: works with existing TaskItem animations

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 完成检查清单

功能完成后，确认以下内容：

- [ ] 粒子组件定义正确，动画流畅
- [ ] 粒子容器z-index正确，不被遮挡
- [ ] playCompletionAnimation函数正确创建6个粒子
- [ ] checkbox完成时触发粒子动画
- [ ] 防重复机制正常工作
- [ ] 粒子对象在动画结束后被销毁
- [ ] 性能测试通过，无卡顿
- [ ] 与现有动画协调一致
- [ ] 所有代码已提交到git
- [ ] 功能符合设计文档要求
