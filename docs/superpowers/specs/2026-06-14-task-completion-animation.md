# 任务完成动画增强设计文档

**版本**: 1.0  
**日期**: 2026-06-14  
**状态**: 设计阶段

---

## 1. 概述

### 1.1 功能描述

当用户完成任务（勾选checkbox）时，从checkbox位置散发5-8个温暖色系的小圆点粒子，向四周飞散并淡出，同时卡片淡化到半透明状态并添加删除线。整个动画持续1000ms，营造微妙的庆祝仪式感。

### 1.2 用户场景

- 用户在今日任务列表中勾选"完成高数作业第三章"的checkbox
- Checkbox变为选中状态，背景填充金色
- 从checkbox位置爆发出6个温暖色小圆点，向四周飞散
- 粒子在飞行过程中逐渐淡出消失
- 任务卡片同时淡化为半透明，文字添加删除线
- 用户感受到完成任务的正向反馈和成就感

### 1.3 设计原则

- **仪式感**：完成任务是值得庆祝的时刻，动画应传递积极情绪
- **克制优雅**：粒子效果微妙，不喧宾夺主，不干扰用户继续操作
- **性能优先**：动画流畅不卡顿，连续完成多个任务也能保持性能
- **主题一致**：粒子颜色使用温暖纸质主题色系，与整体风格融合

---

## 2. 动画设计

### 2.1 粒子系统设计

**粒子属性**：

- 数量：6个（平衡视觉效果和性能）
- 形状：圆形（`border-radius: 50%`）
- 大小：4-6px（随机，增加自然感）
- 颜色：温暖色系三种
  - `#d4a574`（主金色）
  - `#e8dfc8`（浅米色）
  - `#f0e6d2`（极浅米色）
- 初始位置：checkbox中心点

**飞行轨迹**：

粒子向6个方向散开，形成均匀的放射状：

```text
      P1 (↖)
        |
P2(←)--●--P3(→)   ● = checkbox中心
        |
      P4 (↙)
        
    P5(↗)  P6(↘)
```

每个粒子的飞行距离：30-45px（随机）

### 2.2 动画时序

**总时长：1000ms**

```text
0ms ────────────────────────────────────────────────────> 1000ms
│                                                            │
├─ Checkbox背景填充金色 (150ms)
│  
├─ 粒子生成并开始飞散 (0-800ms)
│  ├─ transform: translate 移动
│  └─ opacity: 1 → 0 淡出
│
├─ 卡片淡化 (200-700ms)
│  └─ opacity: 1.0 → 0.7
│
└─ 文字添加删除线 (700-800ms)
```

**分步时序**：

1. **0ms - 150ms**：Checkbox背景从透明填充为金色 `#d4a574`
2. **0ms - 800ms**：粒子从中心点飞散并淡出
   - ease-out 缓动，先快后慢
3. **200ms - 700ms**：卡片整体淡化到 `opacity: 0.7`
4. **700ms - 800ms**：文字颜色变灰 `#8b7355`，添加删除线
5. **1000ms**：动画完成，粒子元素从DOM中移除

### 2.3 视觉效果

**粒子飞行路径示例**（以粒子1为例）：

```javascript
// 粒子1：向左上方飞行
startX: checkboxCenterX
startY: checkboxCenterY
endX: checkboxCenterX - 35px
endY: checkboxCenterY - 35px
```

**颜色分配**（循环使用三种颜色）：
- 粒子0, 3：`#d4a574`
- 粒子1, 4：`#e8dfc8`
- 粒子2, 5：`#f0e6d2`

**视觉层级**：
- 粒子在卡片上方（`z-index: 10`）
- 确保粒子不被卡片边界裁剪（使用绝对定位）

---

## 3. 技术实现

### 3.1 实现方案选择

**不使用Qt Quick Particles的原因**：

- 项目中未使用过粒子系统，引入新依赖会增加复杂度
- Qt Quick Particles 配置较复杂，需要 Emitter、Particle、ParticleSystem 等多个组件
- 纯QML动画实现更轻量，与项目现有动画风格一致
- 6个粒子的简单场景，纯动画性能足够

**选择方案：纯QML SequentialAnimation + 动态创建Rectangle**

### 3.2 QML动画实现

**TaskItem.qml 改造**：

在TaskItem根元素中添加粒子容器和动画逻辑：

```qml
Rectangle {
    id: root
    
    // ... 现有属性 ...
    
    signal completionChanged(int taskId, bool completed)
    
    // 新增：粒子容器
    Item {
        id: particleContainer
        anchors.fill: parent
        z: 10  // 在卡片内容之上
    }
    
    // 新增：粒子组件定义
    Component {
        id: particleComponent
        
        Rectangle {
            id: particle
            width: 5
            height: 5
            radius: 2.5
            opacity: 1.0
            
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
    
    // 新增：触发粒子动画的函数
    function playCompletionAnimation() {
        var checkboxRect = checkbox.mapToItem(root, 0, 0)
        var centerX = checkboxRect.x + checkbox.width / 2
        var centerY = checkboxRect.y + checkbox.height / 2
        
        var colors = ["#d4a574", "#e8dfc8", "#f0e6d2"]
        var directions = [
            {dx: -35, dy: -35},  // 左上
            {dx: -40, dy: 0},    // 左
            {dx: -35, dy: 35},   // 左下
            {dx: 35, dy: -35},   // 右上
            {dx: 40, dy: 0},     // 右
            {dx: 35, dy: 35}     // 右下
        ]
        
        for (var i = 0; i < 6; i++) {
            var particle = particleComponent.createObject(particleContainer, {
                x: centerX,
                y: centerY,
                color: colors[i % 3],
                targetX: centerX + directions[i].dx,
                targetY: centerY + directions[i].dy
            })
        }
    }
    
    // ... 现有代码 ...
    
    CheckBox {
        id: checkbox
        
        checked: root.taskCompleted
        
        onToggled: {
            if (checked) {
                root.playCompletionAnimation()
            }
            root.completionChanged(root.taskId, checked)
        }
        
        // ... 现有indicator代码 ...
    }
}
```

**完整动画协调**：

```qml
// 在 states 中的 completed 状态添加触发
State {
    name: "completed"
    when: root.taskCompleted
    
    PropertyChanges {
        root.opacity: 0.70
        root.completionOffset: 5
    }
    
    // 状态进入时触发粒子动画
    StateChangeScript {
        script: {
            if (!root.animationPlayed) {
                root.playCompletionAnimation()
                root.animationPlayed = true
            }
        }
    }
}

property bool animationPlayed: false

// 取消完成时重置标记
onTaskCompletedChanged: {
    if (!taskCompleted) {
        animationPlayed = false
    }
}
```

### 3.3 性能优化

**优化策略**：

1. **粒子对象池**（可选，复杂度较高）：
   - 如果连续完成多个任务，复用粒子对象而非每次创建
   - 当前实现：动画结束后立即 `destroy()`，简单有效

2. **限制粒子数量**：
   - 固定6个粒子，不随机增减
   - 避免短时间内创建过多DOM元素

3. **动画结束清理**：
   - 动画完成后立即调用 `particle.destroy()`
   - 防止内存泄漏

4. **避免重复触发**：
   - 使用 `animationPlayed` 标记防止状态切换时重复播放
   - 只在用户主动勾选时触发，取消勾选不触发

5. **使用Animator**：
   - OpacityAnimator 比 NumberAnimation on opacity 性能更好
   - 利用渲染线程，不阻塞主线程

**性能测试建议**：
- 连续快速完成10个任务，观察动画流畅度
- 使用 Qt Creator 的 QML Profiler 检测帧率
- 目标：60fps，无明显卡顿

---

## 4. 测试策略

### 4.1 功能测试

- [ ] 勾选任务时触发粒子动画
- [ ] 粒子从checkbox中心散开
- [ ] 6个粒子颜色循环使用三种温暖色
- [ ] 粒子飞行路径为放射状
- [ ] 粒子在飞行过程中淡出
- [ ] 动画结束后粒子对象被销毁
- [ ] 卡片同时淡化到0.7透明度
- [ ] 文字添加删除线并变灰
- [ ] 取消勾选时不触发粒子动画

### 4.2 性能测试

- [ ] 连续完成10个任务，动画保持流畅
- [ ] 使用QML Profiler验证帧率稳定在60fps
- [ ] 内存占用无明显增长（粒子及时销毁）
- [ ] 粒子对象数量不累积（动画结束后清理）

### 4.3 视觉测试

- [ ] 粒子不被卡片边界裁剪
- [ ] 粒子层级在卡片内容之上
- [ ] 粒子大小合适（4-6px清晰可见但不突兀）
- [ ] 动画速度适中（不太快也不太慢）
- [ ] 与现有完成状态动画协调一致

### 4.4 兼容性测试

- [ ] 不影响现有的checkbox交互
- [ ] 不影响"开始专注"和"删除"按钮
- [ ] 不影响任务卡片的其他动画（hover、state transitions）
- [ ] 在不同分辨率下表现正常

---

## 5. 实施计划概要

本功能分为3个主要阶段实施：

### 阶段1：粒子组件实现

- 创建 `particleComponent` 定义
- 实现粒子的飞行动画（transform + opacity）
- 验证单个粒子的动画效果
- 测试粒子销毁逻辑

### 阶段2：粒子系统集成

- 实现 `playCompletionAnimation()` 函数
- 计算checkbox中心点坐标
- 批量创建6个粒子，分配颜色和方向
- 连接到checkbox的 `onToggled` 信号

### 阶段3：动画协调和优化

- 与现有完成状态动画协调时序
- 添加 `animationPlayed` 标记防止重复触发
- 性能测试和优化
- 完整的视觉和交互测试

---

## 6. 文件清单

### 修改文件

- `qml/components/TaskItem.qml` - 添加粒子容器、粒子组件定义、动画触发逻辑

### 无需新建文件

所有功能在TaskItem内部实现，无需额外组件文件

---

## 附录：动画参数调优指南

如果实际效果需要调整，可以修改以下参数：

**粒子数量**：
- 当前：6个
- 可调整为：4-8个（更少=更克制，更多=更热烈）

**飞行距离**：
- 当前：30-40px
- 可调整为：20-50px（更短=更紧凑，更长=更奔放）

**动画时长**：
- 当前：800ms
- 可调整为：600-1000ms（更短=更快捷，更长=更舒展）

**颜色方案**：
- 当前：三种温暖色
- 可替换为其他主题色，或增加颜色种类

**缓动函数**：
- 当前：Easing.OutQuad（先快后慢）
- 可替换为：Easing.OutCubic（更柔和）或 Easing.Linear（匀速）
