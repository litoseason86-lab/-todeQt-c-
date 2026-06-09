# Phase 3.3: 视觉动画优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为应用添加微妙自然的动画效果，提升用户体验流畅度，包括任务完成动画、页面切换、对话框动画、列表交互和统计卡片动画

**Architecture:** 使用 QML 声明式动画（Behavior、Transition、Animator），避免 JavaScript 驱动动画，优先使用 Animator 类型保证性能，所有动画时长控制在 150-300ms

**Tech Stack:** Qt 6, QML, OpacityAnimator, NumberAnimation, ColorAnimation

---

## File Structure Overview

### Modified Files
- `qml/components/TaskItem.qml` - 添加完成动画
- `qml/MainWindow.qml` - 添加页面切换过渡
- `qml/components/AddTaskDialog.qml` - 添加对话框动画
- `qml/components/CategoryDialog.qml` - 添加对话框动画
- `qml/components/ExportDialog.qml` - 添加对话框动画
- `qml/views/StatisticsView.qml` - 添加统计卡片动画
- `qml/components/Sidebar.qml` - 添加悬停效果

---

## Tasks

## Task 1: 添加任务完成动画

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 为 TaskItem 添加状态**

在 TaskItem 根元素中添加：

```qml
states: [
    State {
        name: "normal"
        when: !taskCompleted
        PropertyChanges { target: root; opacity: 1.0 }
    },
    State {
        name: "completed"
        when: taskCompleted
        PropertyChanges { target: root; opacity: 0.6 }
    }
]
```

- [ ] **Step 2: 添加状态切换过渡动画**

在 TaskItem 中添加：

```qml
transitions: [
    Transition {
        from: "normal"
        to: "completed"
        
        ParallelAnimation {
            OpacityAnimator {
                target: root
                duration: 200
                easing.type: Easing.OutQuad
            }
            
            NumberAnimation {
                target: root
                property: "y"
                from: root.y
                to: root.y + 5
                duration: 200
                easing.type: Easing.OutQuad
            }
        }
    },
    Transition {
        from: "completed"
        to: "normal"
        
        OpacityAnimator {
            target: root
            duration: 150
            easing.type: Easing.InQuad
        }
    }
]
```

- [ ] **Step 3: 为任务标题添加删除线**

找到任务标题的 Text 组件，添加：

```qml
font.strikeout: taskCompleted
```

同时添加颜色变化的 Behavior：

```qml
color: taskCompleted ? "#8b7355" : "#5d4e37"

Behavior on color {
    ColorAnimation {
        duration: 200
        easing.type: Easing.OutQuad
    }
}
```

- [ ] **Step 4: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 5: 测试动画效果**

运行应用：

```bash
cd build
./PomodoroTodo
```

测试步骤：
1. 勾选任务复选框
2. 观察任务项淡出并轻微下移
3. 观察文字变灰并添加删除线
4. 取消勾选任务
5. 观察任务恢复正常状态

Expected: 动画流畅自然，时长约 200ms

- [ ] **Step 6: 提交**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat: add subtle completion animation to TaskItem"
```

---

## Task 2: 添加页面切换过渡动画

**Files:**
- Modify: `qml/MainWindow.qml`

- [ ] **Step 1: 找到 StackLayout 或视图切换逻辑**

```bash
cat qml/MainWindow.qml | grep -A 10 "StackLayout\|StackView"
```

- [ ] **Step 2: 如果使用 StackLayout，替换为 StackView**

将 StackLayout 替换为 StackView 以支持过渡动画：

```qml
StackView {
    id: stackView
    Layout.fillWidth: true
    Layout.fillHeight: true
    
    initialItem: todayTaskView
    
    pushEnter: Transition {
        PropertyAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
    
    pushExit: Transition {
        PropertyAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
    
    replaceEnter: Transition {
        PropertyAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
    
    replaceExit: Transition {
        PropertyAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
}
```

- [ ] **Step 3: 更新 Sidebar 导航逻辑**

修改 Sidebar 中的视图切换逻辑使用 StackView.replace：

```qml
onClicked: {
    if (model.viewIndex === 0) {
        stackView.replace(todayTaskView)
    } else if (model.viewIndex === 1) {
        stackView.replace(weekPlanView)
    }
    // ... 其他视图
}
```

- [ ] **Step 4: 如果使用 StackLayout，添加简单淡入淡出**

如果不便替换为 StackView，为 StackLayout 添加 Behavior：

```qml
StackLayout {
    id: stackLayout
    
    Behavior on currentIndex {
        NumberAnimation {
            duration: 0 // StackLayout 不直接支持动画
        }
    }
}

// 为每个视图添加进入动画
Component.onCompleted: {
    opacity = 0
    opacityAnimation.start()
}

OpacityAnimator {
    id: opacityAnimation
    target: root
    from: 0
    to: 1
    duration: 150
    easing.type: Easing.InOutQuad
}
```

- [ ] **Step 5: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 6: 测试页面切换**

运行应用，点击侧边栏切换不同视图

Expected: 页面切换时有淡入淡出效果，流畅自然

- [ ] **Step 7: 提交**

```bash
git add qml/MainWindow.qml qml/components/Sidebar.qml
git commit -m "feat: add fade transition for view switching"
```

---

## Task 3: 添加对话框动画

**Files:**
- Modify: `qml/components/AddTaskDialog.qml`
- Modify: `qml/components/CategoryDialog.qml`
- Modify: `qml/components/ExportDialog.qml`

- [ ] **Step 1: 为 AddTaskDialog 添加打开动画**

在 Dialog 中添加 enter 和 exit 属性：

```qml
Dialog {
    id: dialog
    
    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.95
                to: 1.0
                duration: 200
                easing.type: Easing.OutQuad
            }
            
            OpacityAnimator {
                from: 0
                to: 1
                duration: 200
                easing.type: Easing.OutQuad
            }
        }
    }
    
    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: 150
            easing.type: Easing.InQuad
        }
    }
}
```

- [ ] **Step 2: 添加背景遮罩动画**

为 Dialog 的 Overlay 添加动画：

```qml
Overlay.modal: Rectangle {
    color: "#80000000"
    
    Behavior on opacity {
        OpacityAnimator {
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
}
```

- [ ] **Step 3: 为 CategoryDialog 添加相同动画**

复制 Step 1 和 Step 2 的代码到 CategoryDialog.qml

- [ ] **Step 4: 为 ExportDialog 添加相同动画**

复制 Step 1 和 Step 2 的代码到 ExportDialog.qml

- [ ] **Step 5: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 6: 测试对话框动画**

运行应用，测试所有对话框的打开和关闭：
1. AddTaskDialog（添加任务）
2. CategoryDialog（科目管理）
3. ExportDialog（数据导出）

Expected: 对话框打开时缩放+淡入，关闭时淡出，背景遮罩同步淡入淡出

- [ ] **Step 7: 提交**

```bash
git add qml/components/AddTaskDialog.qml qml/components/CategoryDialog.qml qml/components/ExportDialog.qml
git commit -m "feat: add scale and fade animations to all dialogs"
```

---

## Task 4: 添加列表项悬停效果

**Files:**
- Modify: `qml/components/Sidebar.qml`
- Modify: `qml/components/TaskItem.qml` (if not already present)

- [ ] **Step 1: 为 Sidebar 菜单项添加悬停动画**

找到 Sidebar 中的菜单项 Rectangle，确保有 MouseArea 的 hoverEnabled：

```qml
Rectangle {
    width: parent.width - 20
    height: 40
    radius: 4
    color: mouseArea.containsMouse ? "#f5f3ed" : "transparent"
    
    Behavior on color {
        ColorAnimation {
            duration: 100
            easing.type: Easing.InOutQuad
        }
    }
    
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: { /* navigation logic */ }
    }
}
```

- [ ] **Step 2: 为 TaskItem 添加悬停效果（如果还没有）**

在 TaskItem 的根 Rectangle 中添加：

```qml
Rectangle {
    id: root
    
    color: mouseArea.containsMouse ? "#f5f3ed" : "#faf6ee"
    
    Behavior on color {
        ColorAnimation {
            duration: 100
            easing.type: Easing.InOutQuad
        }
    }
    
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        // 其他交互逻辑
    }
}
```

- [ ] **Step 3: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 4: 测试悬停效果**

运行应用，鼠标悬停在：
1. 侧边栏菜单项
2. 任务列表项
3. 按钮

Expected: 悬停时背景色平滑过渡，鼠标指针变为手型

- [ ] **Step 5: 提交**

```bash
git add qml/components/Sidebar.qml qml/components/TaskItem.qml
git commit -m "feat: add smooth hover effects to interactive elements"
```

---

## Task 5: 添加统计卡片动画

**Files:**
- Modify: `qml/views/StatisticsView.qml`
- Modify: `qml/components/StatCard.qml` (if exists)

- [ ] **Step 1: 为统计数字添加变化动画**

在 StatisticsView 或 StatCard 组件中，为数字 Text 添加：

```qml
Text {
    id: valueText
    text: statisticsValue
    
    Behavior on text {
        SequentialAnimation {
            PropertyAnimation {
                target: valueText
                property: "scale"
                to: 1.1
                duration: 150
                easing.type: Easing.OutQuad
            }
            PropertyAnimation {
                target: valueText
                property: "scale"
                to: 1.0
                duration: 150
                easing.type: Easing.InQuad
            }
        }
    }
}
```

- [ ] **Step 2: 添加统计卡片首次加载动画**

在 StatisticsView 中，为统计卡片添加依次淡入效果：

```qml
Component.onCompleted: {
    staggerAnimation.start()
}

SequentialAnimation {
    id: staggerAnimation
    
    Repeater {
        model: [statCard1, statCard2, statCard3]
        
        SequentialAnimation {
            PauseAnimation {
                duration: index * 50
            }
            
            ParallelAnimation {
                OpacityAnimator {
                    target: modelData
                    from: 0
                    to: 1
                    duration: 200
                    easing.type: Easing.OutQuad
                }
                
                NumberAnimation {
                    target: modelData
                    property: "y"
                    from: modelData.y + 10
                    to: modelData.y
                    duration: 200
                    easing.type: Easing.OutQuad
                }
            }
        }
    }
}
```

或者简化版本，为每个卡片单独设置：

```qml
StatCard {
    id: statCard1
    opacity: 0
    
    Component.onCompleted: {
        fadeInAnimation.start()
    }
    
    OpacityAnimator {
        id: fadeInAnimation
        target: statCard1
        from: 0
        to: 1
        duration: 200
        easing.type: Easing.OutQuad
    }
}

StatCard {
    id: statCard2
    opacity: 0
    
    Component.onCompleted: {
        fadeInAnimation2.start()
    }
    
    OpacityAnimator {
        id: fadeInAnimation2
        target: statCard2
        from: 0
        to: 1
        duration: 200
        easing.type: Easing.OutQuad
    }
    
    PauseAnimation {
        duration: 50
        running: true
        onFinished: fadeInAnimation2.start()
    }
}

// statCard3 类似，延迟 100ms
```

- [ ] **Step 3: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 4: 测试统计动画**

运行应用，切换到统计视图：
1. 观察卡片依次淡入
2. 完成任务或专注后，观察数字更新动画

Expected: 卡片依次淡入（间隔 50ms），数字变化时有轻微缩放效果

- [ ] **Step 5: 提交**

```bash
git add qml/views/StatisticsView.qml qml/components/StatCard.qml
git commit -m "feat: add stagger fade-in and number change animations to statistics"
```

---

## Task 6: 性能测试和优化

**Files:**
- Test: 所有动画效果

- [ ] **Step 1: 使用 QML Profiler 检测性能**

在 Qt Creator 中：
1. 打开项目
2. 选择 Analyze > QML Profiler
3. 运行应用
4. 触发各种动画
5. 停止 Profiler 并查看结果

关注指标：
- 帧率是否保持 60fps
- 动画期间 CPU 占用
- 是否有掉帧

- [ ] **Step 2: 测试动画流畅度**

手动测试清单：
- [ ] 任务完成动画流畅，无卡顿
- [ ] 页面切换过渡自然
- [ ] 对话框打开/关闭流畅
- [ ] 悬停效果响应及时
- [ ] 统计卡片动画协调
- [ ] 多个动画同时触发时不冲突

- [ ] **Step 3: 测试低配置机器（如有条件）**

在低配置环境测试动画性能

- [ ] **Step 4: 优化（如有需要）**

如果发现性能问题：
- 确认使用 Animator 类型（OpacityAnimator、ScaleAnimator）
- 避免在动画中使用复杂的 JavaScript 计算
- 减少同时运行的动画数量
- 降低动画时长或简化效果

- [ ] **Step 5: 添加动画控制开关（预留）**

在全局配置中添加动画开关：

```qml
// 在 main.qml 或 MainWindow.qml
readonly property bool animationsEnabled: true
readonly property int animationDuration: animationsEnabled ? 200 : 0
```

修改所有动画使用全局时长：

```qml
duration: animationDuration
```

- [ ] **Step 6: 创建测试文档**

在 `docs/testing/phase3-visual-animations-test.md` 创建测试报告：

```markdown
# Phase 3.3 视觉动画优化测试报告

## 测试日期
[填写日期]

## 动画效果测试
- [x] 任务完成动画
- [x] 页面切换过渡
- [x] 对话框动画
- [x] 悬停效果
- [x] 统计卡片动画

## 性能测试
- 帧率：60fps
- 动画流畅度：优秀
- CPU 占用：正常

## 用户体验
- 动画微妙自然
- 不干扰操作
- 提升流畅度

## 结论
视觉动画优化完成，用户体验显著提升。
```

- [ ] **Step 7: 最终提交**

```bash
git add docs/testing/phase3-visual-animations-test.md
git commit -m "test: complete testing for visual animations"
```

- [ ] **Step 8: 创建标签**

```bash
git tag -a v0.3.3 -m "Phase 3.3: Visual animation enhancements"
```

---

## 完成检查清单

Phase 3.3 视觉动画优化完成标准：

- [ ] 所有 6 个任务完成
- [ ] 任务完成动画工作正常
- [ ] 页面切换有淡入淡出效果
- [ ] 所有对话框有打开/关闭动画
- [ ] 列表项悬停效果流畅
- [ ] 统计卡片有依次淡入效果
- [ ] 数字变化有动画反馈
- [ ] 所有动画时长 150-300ms
- [ ] 使用 Animator 类型保证性能
- [ ] 动画流畅不卡顿
- [ ] 帧率保持 60fps
- [ ] 动画微妙自然，不抢眼
- [ ] 多个动画叠加时协调
- [ ] 所有提交消息清晰
- [ ] 代码编译无警告
- [ ] QML Profiler 测试通过
- [ ] 用户体验显著提升

完成 Phase 3.3 后，第三阶段所有功能完成！

---

## Phase 3 总结

第三阶段包含三个子阶段：

1. **Phase 3.1: 科目管理系统** ✓
   - 数据库版本管理和迁移
   - CategoryManager 服务
   - 科目管理 UI
   - 任务科目关联

2. **Phase 3.2: 数据导出功能** ✓
   - ExportService 服务
   - CSV 格式导出
   - 导出对话框
   - UTF-8 编码和字段转义

3. **Phase 3.3: 视觉动画优化** ✓
   - 任务完成动画
   - 页面切换过渡
   - 对话框动画
   - 悬停和统计动画

完成后创建总标签：

```bash
git tag -a v0.3.0 -m "Phase 3: Categories, Export, and Visual Polish Complete"
```

番茄Todo 应用现已功能完整，体验优秀！

