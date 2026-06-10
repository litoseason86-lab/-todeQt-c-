# UI整体优化设计文档

**版本**: 1.0  
**日期**: 2026-06-10  
**阶段**: Phase 3 后续优化

---

## 1. 项目概述

### 1.1 设计目标

### 1.2 优化范围

### 1.3 设计原则

---

## 2. 优化策略

### 2.1 实施方法

### 2.2 优先级设定

---

## 3. 基础视觉层设计

### 3.1 字体系统优化

### 3.2 间距系统优化

### 3.3 圆角和阴影优化

---

## 4. 交互反馈层设计

### 4.1 按钮状态系统

### 4.2 卡片和容器的 hover 状态

### 4.3 输入框和下拉框状态

### 4.4 对话框打开/关闭动画

---

## 5. 色彩层次层设计

### 5.1 色彩语义化

### 5.2 对比度优化

### 5.3 分类色彩系统

### 5.4 视觉层级优化

---

## 6. 核心组件具体优化方案

### 6.1 TaskItem 组件优化

### 6.2 AddTaskDialog 组件优化

### 6.3 TodayTaskView 组件优化

### 6.4 MonthGoalView 组件优化

**文件路径**：`qml/views/MonthGoalView.qml`

**当前状态**：
- 日历网格布局（42个日期格子，7列）
- 右侧任务详情面板（显示选中日期的任务）
- 三个统计卡片（本月任务、已完成、完成率）
- 月份切换按钮（上月、本月、下月）
- 复用 TaskItem 组件显示任务

**优化清单**：

**1. 页面标题和描述优化**（line 126-137）：
```qml
Text {
    text: "月度目标"
    font.pixelSize: 24
    font.weight: Font.Bold  // 从 font.bold: true 改为 Font.Bold
    color: "#5d4e37"
}

Text {
    text: root.currentYear + "年" + root.currentMonth + "月"
    font.pixelSize: 13
    color: "#8b7355"  // 保持当前颜色
}
```

**2. 月份切换按钮优化**（line 146-183，三个按钮）：
```qml
Button {  // "上月"、"本月"、"下月" 三个按钮
    background: Rectangle {
        color: {
            if (button.pressed) return "#d2c9b0"
            if (button.hovered) return "#ddd4bb"
            return "#e8dfc8"
        }
        radius: 4
        
        layer.enabled: button.hovered
        layer.effect: DropShadow {
            horizontalOffset: 0
            verticalOffset: 1
            radius: 4
            samples: 8
            color: "#14000000"
        }
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: button.text
        color: "#5d4e37"
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
```

**3. 统计卡片优化**（line 211-233）：
```qml
// StatCard 组件需要在 qml/components/StatCard.qml 中优化
// 添加层级1阴影（与 TodayTaskView 统计卡片相同）
```

**4. 日历容器优化**（line 243-334）：
```qml
Rectangle {  // 日历外层容器
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1
    
    // 添加层级1阴影
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 1
        radius: 4
        samples: 8
        color: "#14000000"
    }
}
```

**5. 日期格子 hover 状态优化**（line 285-330）：
```qml
Rectangle {  // 日期格子
    radius: 4
    color: dayNumber === root.selectedDay ? "#f0e6d2" : 
           (mouseArea.containsMouse ? "#fffef9" : "#faf6ee")
    border.color: {
        if (dayNumber === root.selectedDay) return "#d4a574"
        if (mouseArea.containsMouse) return "#ddd4bb"
        return "#e8dfc8"
    }
    border.width: dayNumber === root.selectedDay ? 1.5 : 1
    opacity: dayNumber > 0 ? 1.0 : 0.35
    
    Behavior on color {
        ColorAnimation { duration: 150; easing.type: Easing.OutQuad }
    }
    Behavior on border.color {
        ColorAnimation { duration: 150; easing.type: Easing.OutQuad }
    }
    
    MouseArea {
        id: mouseArea  // 添加 id
        anchors.fill: parent
        enabled: parent.dayNumber > 0
        hoverEnabled: true  // 启用 hover
        cursorShape: Qt.PointingHandCursor
        onClicked: root.selectedDay = parent.dayNumber
    }
}
```

**6. 日期数字文字优化**（line 306-312）：
```qml
Text {
    text: dayNumber > 0 ? String(dayNumber) : ""
    font.pixelSize: 13
    font.weight: dayNumber === root.selectedDay ? Font.Bold : Font.Normal
    color: "#5d4e37"
}
```

**7. 右侧任务面板容器优化**（line 336-416）：
```qml
Rectangle {  // 右侧面板容器
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1
    
    // 添加层级1阴影
    layer.enabled: true
    layer.effect: DropShadow {
        horizontalOffset: 0
        verticalOffset: 1
        radius: 4
        samples: 8
        color: "#14000000"
    }
}
```

**8. 面板标题文字优化**（line 353-359）：
```qml
Text {
    text: root.currentMonth + "月" + root.selectedDay + "日"
    font.pixelSize: 16
    font.weight: Font.Bold  // 从 font.bold: true 改为 Font.Bold
    color: "#5d4e37"
}
```

**9. "添加"按钮优化**（line 361-366）：
```qml
Button {
    text: "添加"
    implicitWidth: 72
    implicitHeight: 36
    
    background: Rectangle {
        color: {
            if (button.pressed) return "#b8905e"
            if (button.hovered) return "#c9a06a"
            return "#d4a574"
        }
        radius: 4
        scale: button.hovered ? 1.02 : 1.0
        
        layer.enabled: button.hovered
        layer.effect: DropShadow {
            horizontalOffset: 0
            verticalOffset: 1
            radius: 4
            samples: 8
            color: "#14000000"
        }
        
        Behavior on scale {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: button.text
        color: "#fffef9"
        font.pixelSize: 13
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
```

**注意事项**：
- MonthGoalView 复用了 TaskItem 组件，TaskItem 的优化会自动应用
- 统计卡片使用 StatCard 组件，需要在 StatCard.qml 中统一优化
- 日历格子的 hover 效果应该微妙，不要过于抢眼
- 月份切换按钮使用次要按钮样式

