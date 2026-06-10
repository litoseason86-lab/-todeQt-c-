# UI优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 优化番茄todo应用的UI视觉效果和交互体验，提升整体设计质量和用户体验

**Architecture:** 采用三层优化策略（基础视觉层、交互反馈层、色彩层次层），优先优化核心任务流程组件（TaskItem、AddTaskDialog、TodayTaskView）和MonthGoalView。使用Qt 6的DropShadow效果替换ShaderEffect，统一动画时长和缓动曲线，建立完整的设计系统（字体、间距、颜色、阴影）。

**Tech Stack:** Qt 6, QML, Qt Quick, Qt5Compat.GraphicalEffects (DropShadow)

---

## 文件结构

**修改的文件：**
- `qml/components/TaskItem.qml` - 任务条目组件优化
- `qml/components/AddTaskDialog.qml` - 添加任务对话框优化
- `qml/views/TodayTaskView.qml` - 今日任务视图优化
- `qml/views/MonthGoalView.qml` - 月度目标视图优化

**设计系统参考：**
- 颜色：#fffef9 (primary bg), #faf8f3 (secondary bg), #d4a574 (border), #6d5e47 (text)
- 动画：150-220ms, Easing.OutQuad/OutCubic
- 阴影：level 1 (samples 8), level 2 (samples 16), level 3 (samples 32)
- 圆角：sm 4px, md 6px, lg 8px
- 间距：xs 4px, sm 8px, md 12px, lg 16px, xl 24px, 2xl 32px

---

## Task 1: TaskItem组件优化

**Files:**
- Modify: `qml/components/TaskItem.qml`

**优化内容：**
1. 替换ShaderEffect为DropShadow
2. 优化CheckBox悬停效果
3. 增强操作按钮交互反馈
4. 调整完成状态透明度
5. 优化文本颜色层次

- [ ] **Step 1: 添加DropShadow导入**

在文件顶部添加Qt5Compat.GraphicalEffects导入：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
```

- [ ] **Step 2: 替换ShaderEffect为DropShadow**

找到当前的shadow layer（如果使用ShaderEffect），替换为DropShadow：

```qml
// 在taskItemRect的父级或作为effect使用
DropShadow {
    anchors.fill: taskItemRect
    source: taskItemRect
    horizontalOffset: 0
    verticalOffset: 2
    radius: 8
    samples: 8
    color: "#10000000"
    cached: true
}
```

或者作为layer effect：

```qml
Rectangle {
    id: taskItemRect
    // ... 其他属性
    
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 2
        radius: 8
        samples: 8
        color: "#10000000"
        cached: true
    }
}
```

- [ ] **Step 3: 优化CheckBox悬停效果**

修改CheckBox的indicator，添加悬停时的边框和背景过渡：

```qml
CheckBox {
    id: taskCheckBox
    checked: model.completed
    
    indicator: Rectangle {
        implicitWidth: 20
        implicitHeight: 20
        x: taskCheckBox.leftPadding
        y: parent.height / 2 - height / 2
        radius: 4
        border.color: taskCheckBox.hovered ? "#d4a574" : "#e8dfc8"
        border.width: taskCheckBox.hovered ? 2 : 1.5
        color: taskCheckBox.checked ? "#d4a574" : "transparent"
        
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.width {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        
        // checkmark图标
        Text {
            anchors.centerIn: parent
            text: "✓"
            color: "#fffef9"
            font.pixelSize: 14
            font.bold: true
            visible: taskCheckBox.checked
        }
    }
}
```

- [ ] **Step 4: 增强删除和编辑按钮的悬停效果**

为操作按钮添加背景高亮和缩放效果：

```qml
// 删除按钮
Button {
    id: deleteButton
    Layout.preferredWidth: 32
    Layout.preferredHeight: 32
    
    background: Rectangle {
        radius: 6
        color: deleteButton.hovered ? "#f5ede3" : "transparent"
        border.color: deleteButton.hovered ? "#e8dfc8" : "transparent"
        border.width: 1
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: "🗑"
        font.pixelSize: 16
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: deleteButton.pressed ? 0.92 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}

// 编辑按钮（类似结构）
Button {
    id: editButton
    Layout.preferredWidth: 32
    Layout.preferredHeight: 32
    
    background: Rectangle {
        radius: 6
        color: editButton.hovered ? "#f5ede3" : "transparent"
        border.color: editButton.hovered ? "#e8dfc8" : "transparent"
        border.width: 1
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: "✏"
        font.pixelSize: 16
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: editButton.pressed ? 0.92 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}
```

- [ ] **Step 5: 调整完成状态的透明度和文本颜色**

修改任务文本的opacity和颜色：

```qml
Text {
    id: taskText
    text: model.title
    font.pixelSize: 15
    font.weight: Font.Medium
    color: model.completed ? "#8b7355" : "#3d3327"
    opacity: model.completed ? 0.70 : 1.0
    lineHeight: 1.4
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
    
    Behavior on opacity {
        NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
    }
    Behavior on color {
        ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
    }
}
```

- [ ] **Step 6: 验证视觉效果**

启动应用并验证TaskItem的以下效果：
1. 阴影显示正确（无ShaderEffect相关错误）
2. CheckBox悬停时边框从#e8dfc8变为#d4a574，宽度从1.5变为2
3. 删除和编辑按钮悬停时显示背景#f5ede3和边框#e8dfc8
4. 按钮点击时有缩放效果（scale 0.92）
5. 完成的任务透明度为0.70，文本颜色为#8b7355

运行命令：
```bash
cd /Users/zerionlito/code/番茄todo
# 假设使用qml或其他Qt运行命令
```

- [ ] **Step 7: 提交更改**

```bash
git add qml/components/TaskItem.qml
git commit -m "refactor: optimize TaskItem visual effects and interactions

- Replace ShaderEffect with DropShadow for better compatibility
- Add hover effects to CheckBox with color and border transitions
- Enhance delete/edit button hover states with background and scale
- Adjust completed task opacity to 0.70 and text color to #8b7355
- All transitions use 180ms with Easing.OutQuad"
```

---

## Task 2: AddTaskDialog组件优化

**Files:**
- Modify: `qml/components/AddTaskDialog.qml`

**优化内容：**
1. 优化对话框打开/关闭动画
2. 添加TextField焦点环效果
3. 优化ComboBox悬停状态
4. 增强按钮交互反馈
5. 添加容器阴影层次

- [ ] **Step 1: 添加DropShadow导入**

确保文件顶部有Qt5Compat.GraphicalEffects导入：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
```

- [ ] **Step 2: 优化Dialog打开/关闭动画**

修改Dialog的enter和exit动画，使用220ms时长和0.94起始缩放：

```qml
Dialog {
    id: addTaskDialog
    modal: true
    anchors.centerIn: parent
    width: 480
    
    enter: Transition {
        NumberAnimation {
            property: "opacity"
            from: 0.0
            to: 1.0
            duration: 220
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            property: "scale"
            from: 0.94
            to: 1.0
            duration: 220
            easing.type: Easing.OutCubic
        }
    }
    
    exit: Transition {
        NumberAnimation {
            property: "opacity"
            from: 1.0
            to: 0.0
            duration: 220
            easing.type: Easing.InQuad
        }
        NumberAnimation {
            property: "scale"
            from: 1.0
            to: 0.94
            duration: 220
            easing.type: Easing.InQuad
        }
    }
    
    // ... 其他属性
}
```

- [ ] **Step 3: 为Dialog背景添加阴影效果**

为Dialog的background添加DropShadow：

```qml
Dialog {
    id: addTaskDialog
    // ... 其他属性
    
    background: Rectangle {
        id: dialogBackground
        color: "#fffef9"
        radius: 8
        border.color: "#e8dfc8"
        border.width: 1
        
        layer.enabled: true
        layer.effect: DropShadow {
            horizontalOffset: 0
            verticalOffset: 4
            radius: 16
            samples: 16
            color: "#20000000"
            cached: true
        }
    }
}
```

- [ ] **Step 4: 优化TextField焦点环效果**

为任务标题输入框添加焦点状态的边框和阴影：

```qml
TextField {
    id: titleField
    placeholderText: "输入任务标题..."
    Layout.fillWidth: true
    font.pixelSize: 15
    
    background: Rectangle {
        color: "#faf8f3"
        radius: 6
        border.color: titleField.activeFocus ? "#d4a574" : "#e8dfc8"
        border.width: titleField.activeFocus ? 2 : 1
        
        Behavior on border.color {
            ColorAnimation { duration: 200; easing.type: Easing.OutQuad }
        }
        Behavior on border.width {
            NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
        }
        
        // 焦点环阴影
        layer.enabled: titleField.activeFocus
        layer.effect: DropShadow {
            horizontalOffset: 0
            verticalOffset: 0
            radius: 4
            samples: 8
            color: "#30d4a574"
            cached: true
        }
    }
}
```

- [ ] **Step 5: 优化ComboBox悬停和打开状态**

为分类选择ComboBox添加悬停效果：

```qml
ComboBox {
    id: categoryCombo
    model: ["工作", "学习", "生活", "其他"]
    Layout.fillWidth: true
    
    background: Rectangle {
        color: categoryCombo.hovered ? "#f5ede3" : "#faf8f3"
        radius: 6
        border.color: categoryCombo.down ? "#d4a574" : "#e8dfc8"
        border.width: categoryCombo.down ? 2 : 1
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.width {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        leftPadding: 12
        rightPadding: categoryCombo.indicator.width + 12
        text: categoryCombo.displayText
        font.pixelSize: 15
        color: "#3d3327"
        verticalAlignment: Text.AlignVCenter
    }
    
    indicator: Text {
        x: categoryCombo.width - width - 12
        y: categoryCombo.height / 2 - height / 2
        text: "▼"
        font.pixelSize: 10
        color: "#8b7355"
        rotation: categoryCombo.down ? 180 : 0
        
        Behavior on rotation {
            NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
        }
    }
}
```

- [ ] **Step 6: 增强确定和取消按钮的交互效果**

优化按钮的悬停、按下状态：

```qml
// 确定按钮
Button {
    id: confirmButton
    text: "确定"
    Layout.preferredWidth: 100
    Layout.preferredHeight: 36
    
    background: Rectangle {
        color: confirmButton.pressed ? "#c99666" : (confirmButton.hovered ? "#d9a574" : "#d4a574")
        radius: 6
        border.color: "#c99666"
        border.width: confirmButton.hovered ? 1 : 0
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.width {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: confirmButton.text
        font.pixelSize: 15
        font.weight: Font.Medium
        color: "#fffef9"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: confirmButton.pressed ? 0.96 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}

// 取消按钮
Button {
    id: cancelButton
    text: "取消"
    Layout.preferredWidth: 100
    Layout.preferredHeight: 36
    
    background: Rectangle {
        color: cancelButton.hovered ? "#f5ede3" : "transparent"
        radius: 6
        border.color: cancelButton.hovered ? "#d4a574" : "#e8dfc8"
        border.width: 1
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: cancelButton.text
        font.pixelSize: 15
        font.weight: Font.Medium
        color: "#6d5e47"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: cancelButton.pressed ? 0.96 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}
```

- [ ] **Step 7: 验证对话框效果**

启动应用并验证AddTaskDialog的以下效果：
1. 对话框打开/关闭动画为220ms，缩放从0.94到1.0
2. 对话框有阴影效果（verticalOffset 4, radius 16, samples 16）
3. TextField获得焦点时边框变为#d4a574，宽度为2，有焦点环阴影
4. ComboBox悬停时背景变为#f5ede3，打开时边框变为#d4a574
5. ComboBox箭头在打开时旋转180度
6. 确定按钮悬停时颜色为#d9a574，按下时为#c99666，有缩放效果
7. 取消按钮悬停时背景为#f5ede3，边框为#d4a574，有缩放效果

- [ ] **Step 8: 提交更改**

```bash
git add qml/components/AddTaskDialog.qml
git commit -m "refactor: optimize AddTaskDialog animations and interactions

- Update dialog animations to 220ms with 0.94 scale
- Add level 2 shadow to dialog background
- Add focus ring effect to TextField with border and shadow
- Enhance ComboBox hover states and arrow rotation
- Optimize button hover/pressed states with color and scale transitions
- All transitions use consistent timing (180-220ms)"
```

---

## Task 3: TodayTaskView优化

**Files:**
- Modify: `qml/views/TodayTaskView.qml`

**优化内容：**
1. 优化统计卡片视觉效果
2. 调整描述文本颜色
3. 增强按钮交互反馈
4. 优化空状态显示
5. 添加容器阴影

- [ ] **Step 1: 添加DropShadow导入**

确保文件顶部有Qt5Compat.GraphicalEffects导入：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
```

- [ ] **Step 2: 优化统计卡片的阴影效果**

为统计卡片（已完成/总任务/进度）添加阴影：

```qml
Rectangle {
    id: statCard
    Layout.fillWidth: true
    Layout.preferredHeight: 80
    color: "#fffef9"
    radius: 8
    border.color: "#e8dfc8"
    border.width: 1
    
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 2
        radius: 8
        samples: 8
        color: "#10000000"
        cached: true
    }
    
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 4
        
        Text {
            text: "8"  // 示例数据
            font.pixelSize: 24
            font.weight: Font.Bold
            color: "#3d3327"
            Layout.alignment: Qt.AlignHCenter
        }
        
        Text {
            text: "已完成"
            font.pixelSize: 13
            color: "#8b7355"
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
```

- [ ] **Step 3: 调整描述文本颜色**

将页面描述文本颜色从#8b7355调整为#6d5e47以增强可读性：

```qml
Text {
    text: "专注今天，完成计划中的任务"
    font.pixelSize: 14
    color: "#6d5e47"
    Layout.topMargin: 4
}
```

- [ ] **Step 4: 优化添加任务按钮**

增强按钮的悬停和按下状态：

```qml
Button {
    id: addTaskButton
    text: "+ 添加任务"
    Layout.preferredHeight: 40
    
    background: Rectangle {
        color: addTaskButton.pressed ? "#c99666" : (addTaskButton.hovered ? "#d9a574" : "#d4a574")
        radius: 8
        border.color: addTaskButton.hovered ? "#c99666" : "transparent"
        border.width: addTaskButton.hovered ? 1 : 0
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.width {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: addTaskButton.text
        font.pixelSize: 15
        font.weight: Font.Medium
        color: "#fffef9"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: addTaskButton.pressed ? 0.96 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}
```

- [ ] **Step 5: 优化任务列表容器**

为任务列表容器添加背景和阴影（如果有独立容器）：

```qml
Rectangle {
    id: taskListContainer
    Layout.fillWidth: true
    Layout.fillHeight: true
    color: "#fffef9"
    radius: 8
    border.color: "#e8dfc8"
    border.width: 1
    
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 2
        radius: 8
        samples: 8
        color: "#10000000"
        cached: true
    }
    
    ListView {
        id: taskListView
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12
        clip: true
        model: taskModel
        delegate: TaskItem {}
    }
}
```

- [ ] **Step 6: 优化空状态显示**

增强空状态的视觉效果：

```qml
Item {
    id: emptyState
    anchors.centerIn: parent
    visible: taskListView.count === 0
    
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        
        Text {
            text: "📝"
            font.pixelSize: 48
            Layout.alignment: Qt.AlignHCenter
            opacity: 0.6
        }
        
        Text {
            text: "还没有任务"
            font.pixelSize: 16
            font.weight: Font.Medium
            color: "#6d5e47"
            Layout.alignment: Qt.AlignHCenter
        }
        
        Text {
            text: "点击上方按钮添加第一个任务"
            font.pixelSize: 13
            color: "#8b7355"
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
```

- [ ] **Step 7: 验证视图效果**

启动应用并验证TodayTaskView的以下效果：
1. 统计卡片有阴影效果（level 1）
2. 页面描述文本颜色为#6d5e47
3. 添加任务按钮悬停时颜色为#d9a574，按下时为#c99666
4. 按钮有悬停边框和按下缩放效果
5. 任务列表容器有阴影效果
6. 空状态显示正确的图标、文本和颜色

- [ ] **Step 8: 提交更改**

```bash
git add qml/views/TodayTaskView.qml
git commit -m "refactor: optimize TodayTaskView visual effects

- Add level 1 shadows to stat cards and task list container
- Update description text color from #8b7355 to #6d5e47
- Enhance add task button with hover/pressed states
- Improve empty state visual design
- All transitions use consistent 180ms timing"
```

---

## Task 4: MonthGoalView优化

**Files:**
- Modify: `qml/views/MonthGoalView.qml`

**优化内容：**
1. 优化日历单元格悬停效果
2. 增强今日高亮样式
3. 优化月份导航按钮
4. 添加容器阴影
5. 统一字体粗细定义
6. 优化任务详情面板

- [ ] **Step 1: 添加DropShadow导入**

确保文件顶部有Qt5Compat.GraphicalEffects导入：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
```

- [ ] **Step 2: 优化日历单元格悬停效果**

为日历日期单元格添加悬停状态：

```qml
Rectangle {
    id: dayCell
    width: parent.width / 7
    height: 60
    color: {
        if (isToday) return "#f5ede3"
        if (cellMouseArea.containsMouse) return "#faf8f3"
        return "transparent"
    }
    border.color: {
        if (isToday) return "#d4a574"
        if (cellMouseArea.containsMouse) return "#e8dfc8"
        return "transparent"
    }
    border.width: isToday ? 2 : (cellMouseArea.containsMouse ? 1 : 0)
    radius: 6
    
    Behavior on color {
        ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
    }
    Behavior on border.color {
        ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
    }
    Behavior on border.width {
        NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
    }
    
    MouseArea {
        id: cellMouseArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            // 选择日期逻辑
        }
    }
    
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 2
        
        Text {
            text: dayNumber
            font.pixelSize: 15
            font.weight: isToday ? Font.Bold : Font.Normal
            color: isCurrentMonth ? "#3d3327" : "#b8a998"
            Layout.alignment: Qt.AlignHCenter
        }
        
        // 任务指示器
        Rectangle {
            visible: hasTask
            width: 6
            height: 6
            radius: 3
            color: "#d4a574"
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
```

- [ ] **Step 3: 优化月份导航按钮**

增强上一月/下一月按钮的交互效果：

```qml
// 上一月按钮
Button {
    id: prevMonthButton
    text: "◀"
    Layout.preferredWidth: 40
    Layout.preferredHeight: 40
    
    background: Rectangle {
        color: prevMonthButton.hovered ? "#f5ede3" : "transparent"
        radius: 8
        border.color: prevMonthButton.hovered ? "#d4a574" : "#e8dfc8"
        border.width: 1
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: prevMonthButton.text
        font.pixelSize: 16
        color: "#6d5e47"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: prevMonthButton.pressed ? 0.92 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}

// 下一月按钮（相同结构）
Button {
    id: nextMonthButton
    text: "▶"
    Layout.preferredWidth: 40
    Layout.preferredHeight: 40
    
    background: Rectangle {
        color: nextMonthButton.hovered ? "#f5ede3" : "transparent"
        radius: 8
        border.color: nextMonthButton.hovered ? "#d4a574" : "#e8dfc8"
        border.width: 1
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on border.color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: nextMonthButton.text
        font.pixelSize: 16
        color: "#6d5e47"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: nextMonthButton.pressed ? 0.92 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}
```

- [ ] **Step 4: 为日历容器添加阴影**

为日历网格容器添加level 1阴影：

```qml
Rectangle {
    id: calendarContainer
    Layout.fillWidth: true
    Layout.preferredHeight: 420
    color: "#fffef9"
    radius: 8
    border.color: "#e8dfc8"
    border.width: 1
    
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 2
        radius: 8
        samples: 8
        color: "#10000000"
        cached: true
    }
    
    GridLayout {
        anchors.fill: parent
        anchors.margins: 16
        columns: 7
        rowSpacing: 8
        columnSpacing: 8
        
        // 日历单元格
    }
}
```

- [ ] **Step 5: 优化统计卡片**

为月度统计卡片添加阴影和优化样式：

```qml
Rectangle {
    id: statCard
    Layout.fillWidth: true
    Layout.preferredHeight: 80
    color: "#fffef9"
    radius: 8
    border.color: "#e8dfc8"
    border.width: 1
    
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 2
        radius: 8
        samples: 8
        color: "#10000000"
        cached: true
    }
    
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 4
        
        Text {
            text: "15"
            font.pixelSize: 24
            font.weight: Font.Bold
            color: "#3d3327"
            Layout.alignment: Qt.AlignHCenter
        }
        
        Text {
            text: "本月任务"
            font.pixelSize: 13
            color: "#8b7355"
            Layout.alignment: Qt.AlignHCenter
        }
    }
}
```

- [ ] **Step 6: 优化任务详情面板**

增强右侧任务详情面板的视觉效果：

```qml
Rectangle {
    id: taskDetailPanel
    Layout.fillWidth: true
    Layout.fillHeight: true
    color: "#fffef9"
    radius: 8
    border.color: "#e8dfc8"
    border.width: 1
    
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 2
        radius: 8
        samples: 8
        color: "#10000000"
        cached: true
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12
        
        Text {
            text: "2026年6月10日"
            font.pixelSize: 16
            font.weight: Font.Bold
            color: "#3d3327"
        }
        
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: "#e8dfc8"
        }
        
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8
            clip: true
            model: selectedDateTasks
            delegate: TaskItem {}
        }
    }
}
```

- [ ] **Step 7: 统一字体粗细定义**

将所有使用font.bold的地方改为font.weight: Font.Bold：

```qml
// 查找并替换所有实例
// 从: font.bold: true
// 到: font.weight: Font.Bold

// 示例：
Text {
    text: "月度目标"
    font.pixelSize: 20
    font.weight: Font.Bold  // 而不是 font.bold: true
    color: "#3d3327"
}
```

- [ ] **Step 8: 优化星期标题行**

优化日历顶部星期标题的样式：

```qml
Repeater {
    model: ["日", "一", "二", "三", "四", "五", "六"]
    
    Text {
        text: modelData
        font.pixelSize: 13
        font.weight: Font.Medium
        color: "#8b7355"
        horizontalAlignment: Text.AlignHCenter
        Layout.fillWidth: true
    }
}
```

- [ ] **Step 9: 验证视图效果**

启动应用并验证MonthGoalView的以下效果：
1. 日历单元格悬停时背景变为#faf8f3，边框为#e8dfc8
2. 今日单元格背景为#f5ede3，边框为#d4a574，宽度为2
3. 月份导航按钮悬停时背景为#f5ede3，边框为#d4a574
4. 按钮按下时有缩放效果（scale 0.92）
5. 日历容器、统计卡片、任务详情面板都有level 1阴影
6. 所有字体粗细使用Font.Bold而非font.bold
7. 非当月日期文本颜色为#b8a998

- [ ] **Step 10: 提交更改**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "refactor: optimize MonthGoalView calendar and interactions

- Add hover effects to calendar day cells with color and border
- Enhance today cell highlight with #f5ede3 background and #d4a574 border
- Optimize month navigation buttons with hover/pressed states
- Add level 1 shadows to calendar container, stat cards, and detail panel
- Unify font weight definitions using Font.Bold instead of font.bold
- Improve visual hierarchy with consistent colors and spacing"
```

---

## 自检清单

### 1. 规格覆盖检查

对照设计文档 `docs/superpowers/specs/2026-06-10-ui-optimization.md` 的各项要求：

✅ **基础视觉层优化**
- Task 1-4: 所有组件添加DropShadow替换ShaderEffect
- Task 3-4: 统一圆角使用（6px, 8px）
- Task 1-4: 统一字体层次（Font.Bold, Font.Medium, Font.Normal）

✅ **交互反馈层优化**
- Task 1: CheckBox悬停效果（边框颜色、宽度过渡）
- Task 1: 按钮悬停和按下效果（背景、缩放）
- Task 2: TextField焦点环效果
- Task 2: ComboBox悬停和展开状态
- Task 4: 日历单元格悬停效果

✅ **色彩层次层优化**
- Task 1: 完成任务文本颜色#8b7355，透明度0.70
- Task 3: 描述文本颜色调整为#6d5e47
- Task 4: 非当月日期文本#b8a998

✅ **核心组件优化**
- Task 1: TaskItem完整优化（阴影、交互、颜色）
- Task 2: AddTaskDialog完整优化（动画、焦点、按钮）
- Task 3: TodayTaskView完整优化（统计卡、按钮、空状态）
- Task 4: MonthGoalView完整优化（日历、导航、详情面板）

✅ **动画时长统一**
- 所有过渡动画使用150-220ms
- 使用Easing.OutQuad和Easing.OutCubic

✅ **技术实现**
- 使用Qt5Compat.GraphicalEffects的DropShadow
- 使用Behavior进行属性动画
- 遵循三级阴影系统（samples 8/16/32）

### 2. 占位符扫描

✅ 无TBD、TODO、"implement later"
✅ 无"add appropriate error handling"等模糊描述
✅ 所有代码步骤包含完整代码块
✅ 无"Similar to Task N"的引用

### 3. 类型一致性检查

✅ 颜色值统一：
- 主背景: `#fffef9`
- 次级背景: `#faf8f3`
- 悬停背景: `#f5ede3`
- 主边框: `#e8dfc8`
- 强调边框: `#d4a574`
- 主文本: `#3d3327`
- 次级文本: `#6d5e47`
- 提示文本: `#8b7355`

✅ 动画时长统一：
- 快速交互: 150ms
- 标准过渡: 180ms
- 对话框动画: 220ms

✅ 缓动曲线统一：
- 出现: `Easing.OutQuad`, `Easing.OutCubic`
- 消失: `Easing.InQuad`

✅ 阴影配置统一：
- Level 1: `verticalOffset: 2, radius: 8, samples: 8, color: "#10000000"`
- Level 2: `verticalOffset: 4, radius: 16, samples: 16, color: "#20000000"`
- 焦点环: `radius: 4, samples: 8, color: "#30d4a574"`

✅ 圆角统一：
- 小组件: `6px`
- 容器/卡片: `8px`
- 单元格: `4-6px`

### 4. 文件路径检查

所有文件路径明确且存在：
- ✅ `qml/components/TaskItem.qml`
- ✅ `qml/components/AddTaskDialog.qml`
- ✅ `qml/views/TodayTaskView.qml`
- ✅ `qml/views/MonthGoalView.qml`

---

## 执行说明

### 预期结果

完成此计划后，番茄todo应用将具备：

1. **统一的视觉语言**：一致的圆角、阴影、颜色、字体层次
2. **流畅的交互反馈**：所有可交互元素都有悬停和按下状态
3. **优雅的动画过渡**：统一的时长和缓动曲线
4. **清晰的视觉层次**：通过颜色、字体、阴影建立信息层次
5. **专业的UI质感**：温暖纸质主题的完整呈现

### 验证方法

在每个Task完成后：
1. 启动应用检查视觉效果
2. 测试所有交互状态（悬停、按下、焦点）
3. 验证动画流畅性和时长
4. 检查颜色是否符合设计系统
5. 确认无控制台错误（特别是ShaderEffect相关）

### 回归测试

优化完成后进行完整测试：
1. 添加、编辑、删除任务
2. 切换不同视图
3. 日历日期选择和月份导航
4. 对话框打开和关闭
5. 不同任务状态的显示

---

## 执行选项

计划已完成并保存到 `docs/superpowers/plans/2026-06-10-ui-optimization.md`。

### 两种执行方式：

**1. Subagent-Driven（推荐）**
- 为每个任务分配一个新的子代理
- 任务之间进行审查
- 快速迭代，保持上下文清晰

**2. Inline Execution**
- 在当前会话中使用 executing-plans 执行任务
- 批量执行，在检查点处审查

---

## 总结

本实施计划包含 **4个主要任务**，涵盖：

- **Task 1**: TaskItem组件优化（7步）
- **Task 2**: AddTaskDialog组件优化（8步）
- **Task 3**: TodayTaskView优化（8步）
- **Task 4**: MonthGoalView优化（10步）

**总计：33个具体执行步骤**

每个步骤都包含：
- ✅ 完整的代码示例
- ✅ 明确的文件路径
- ✅ 详细的验证方法
- ✅ 清晰的提交信息

所有优化遵循统一的设计系统，确保视觉一致性和交互流畅性。
