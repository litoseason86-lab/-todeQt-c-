# UI整体优化设计文档

**版本**: 1.0  
**日期**: 2026-06-10  
**阶段**: Phase 3 后续优化

---

## 1. 项目概述

### 1.1 设计目标

本次UI优化的核心目标是提升番茄todo应用的视觉精致度和用户体验质量，建立统一的设计语言系统。具体目标包括：

1. **视觉一致性**：建立完整的设计系统（颜色、字体、间距、圆角、阴影），确保所有组件遵循统一的视觉规范
2. **交互流畅性**：优化所有交互元素的反馈效果，提供清晰的视觉状态变化（悬停、按下、聚焦、激活）
3. **信息层次感**：通过色彩、字体、阴影建立清晰的视觉层次，引导用户注意力
4. **温暖质感**：强化温暖纸质主题，营造舒适的视觉氛围
5. **技术规范化**：使用标准的Qt组件和效果（DropShadow），替换非标准实现（ShaderEffect）

### 1.2 优化范围

**核心组件（P0优先级）**：
- `TaskItem.qml` - 任务条目组件
- `AddTaskDialog.qml` - 添加任务对话框
- `TodayTaskView.qml` - 今日任务视图
- `MonthGoalView.qml` - 月度目标视图

**优化维度**：
- 基础视觉层：字体、间距、圆角、阴影
- 交互反馈层：按钮、输入框、下拉框、对话框的状态效果
- 色彩层次层：文本颜色、背景颜色、边框颜色的语义化和层次优化

**不包含的内容**：
- 功能性修改（保持现有功能不变）
- 新增UI组件
- 布局结构重构
- 响应式设计调整

### 1.3 设计原则

1. **渐进式优化**：在现有实现基础上优化，避免大规模重构
2. **遵循Qt规范**：使用Qt官方推荐的组件和API
3. **性能优先**：使用高效的动画方式（Behavior + Animator），启用缓存（cached: true）
4. **向后兼容**：确保优化不影响现有功能
5. **可维护性**：建立统一的设计token，便于后续维护和扩展

---

## 2. 优化策略

### 2.1 实施方法

采用**组件层优化 + 用户旅程优化**的混合策略：

**组件层优化**：
- 自底向上优化核心组件（TaskItem → AddTaskDialog → View层）
- 建立可复用的设计模式和代码片段
- 确保组件间视觉一致性

**用户旅程优化**：
- 优先优化核心任务流程（添加任务 → 查看任务 → 完成任务 → 开始专注）
- 确保关键路径的交互流畅性
- 优化月度目标查看体验

**三层优化架构**：
1. **基础视觉层**（Foundation）：字体、间距、圆角、阴影的系统化定义
2. **交互反馈层**（Interaction）：悬停、按下、聚焦、激活状态的统一处理
3. **色彩层次层**（Hierarchy）：通过颜色建立信息优先级和视觉引导

### 2.2 优先级设定

**P0 - 必须实现**：
- TaskItem组件完整优化
- AddTaskDialog动画和交互优化
- TodayTaskView核心区域优化
- MonthGoalView日历交互优化
- 替换ShaderEffect为DropShadow（技术债务）

**P1 - 重要优化**：
- 统计卡片视觉增强
- 空状态优化
- 按钮状态系统完善

**P2 - 可选优化**：
- 微交互细节（如加载状态、过渡动画）
- 辅助功能优化（键盘导航）
- 性能优化（动画帧率监控）

---

## 3. 基础视觉层设计

### 3.1 字体系统优化

建立六级字体层次系统，统一使用 `font.weight` 属性替代 `font.bold`：

**字体层次定义**：

| 层级 | 用途 | 大小 | 粗细 | 应用场景 |
|------|------|------|------|----------|
| H1 | 页面主标题 | 24px | Font.Bold | 视图标题（"今日任务"、"月度目标"） |
| H2 | 区块标题 | 16-18px | Font.Bold | 对话框标题、卡片标题 |
| H3 | 统计数字 | 24px | Font.Bold | 统计卡片的数值 |
| Body | 正文内容 | 15px | Font.Medium | 任务标题、按钮文字 |
| Caption | 辅助说明 | 13px | Font.Normal | 描述文字、标签 |
| Small | 次要信息 | 12px | Font.Normal | 提示文字、时间戳 |

**实施规范**：
- 统一使用 `font.weight: Font.Bold` 替代 `font.bold: true`
- 统一使用 `font.weight: Font.Medium` 表示中等粗细
- 统一使用 `font.weight: Font.Normal` 表示常规粗细
- 设置 `lineHeight: 1.4` 提升可读性（适用于多行文本）

**示例代码**：

```qml
// 页面标题
Text {
    text: "今日任务"
    font.pixelSize: 24
    font.weight: Font.Bold
    color: "#3d3327"
}

// 任务标题
Text {
    text: taskTitle
    font.pixelSize: 15
    font.weight: Font.Medium
    lineHeight: 1.4
    color: "#3d3327"
}

// 描述文字
Text {
    text: "专注今天，完成计划中的任务"
    font.pixelSize: 13
    font.weight: Font.Normal
    color: "#6d5e47"
}
```

### 3.2 间距系统优化

基于8px栅格系统建立统一的间距规范：

**间距Token定义**：

| Token | 值 | 用途 |
|-------|-----|------|
| xs | 4px | 紧密间距（图标与文字、标签内边距） |
| sm | 8px | 小间距（列表项间距、小组件内边距） |
| md | 12px | 中等间距（卡片内边距、区块间距） |
| lg | 16px | 大间距（容器内边距、区块间距） |
| xl | 24px | 特大间距（页面边距、主要区块间距） |
| 2xl | 32px | 超大间距（页面顶部间距） |

**应用规则**：

1. **容器内边距**：
   - 小组件（按钮、输入框）：8-12px
   - 卡片、对话框：16px
   - 页面容器：24px

2. **元素间距**：
   - 紧密相关元素：4-8px
   - 同级元素：12-16px
   - 区块间隔：24-32px

3. **列表间距**：
   - TaskItem之间：12px
   - 统计卡片之间：12px
   - 日历单元格之间：6-8px

**示例代码**：

```qml
ColumnLayout {
    spacing: 12  // md间距
    anchors.margins: 16  // lg内边距
    
    // 区块间距
    Layout.topMargin: 24  // xl间距
}
```

### 3.3 圆角和阴影优化

**圆角系统**：

| 层级 | 值 | 应用 |
|------|-----|------|
| sm | 4px | 小组件（CheckBox、Tag、单元格） |
| md | 6px | 中等组件（按钮、输入框） |
| lg | 8px | 大组件（卡片、对话框、容器） |

**阴影系统**：

采用三级阴影系统，使用Qt5Compat.GraphicalEffects的DropShadow：

| 层级 | 配置 | 应用场景 |
|------|------|----------|
| Level 1 | offset(0,2) radius:8 samples:8 color:#10000000 | 卡片、TaskItem、统计卡片 |
| Level 2 | offset(0,4) radius:16 samples:16 color:#20000000 | 对话框、浮层 |
| Level 3 | offset(0,8) radius:32 samples:32 color:#30000000 | 模态层、重要提示（预留） |

**焦点环阴影**：
- offset(0,0) radius:4 samples:8 color:#30d4a574
- 用于输入框和可聚焦元素的焦点状态

**实施规范**：
- 统一使用 `layer.enabled: true` + `layer.effect: DropShadow`
- 启用缓存：`cached: true` 提升性能
- 替换所有 ShaderEffect 实现

**示例代码**：

```qml
Rectangle {
    radius: 8  // lg圆角
    color: "#fffef9"
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
}
```

---

## 4. 交互反馈层设计

### 4.1 按钮状态系统

建立统一的按钮状态系统，包括主按钮、次按钮、文本按钮三种类型：

**主按钮（Primary Button）**：

| 状态 | 背景色 | 边框 | 文字色 | 其他效果 |
|------|--------|------|--------|----------|
| Normal | #d4a574 | 无 | #fffef9 | - |
| Hover | #d9a574 | 1px #c99666 | #fffef9 | - |
| Pressed | #c99666 | 1px #c99666 | #fffef9 | scale: 0.96 |
| Disabled | #ebe6dd | 无 | #a0896b | opacity: 0.6 |

**次按钮（Secondary Button）**：

| 状态 | 背景色 | 边框 | 文字色 | 其他效果 |
|------|--------|------|--------|----------|
| Normal | transparent | 1px #e8dfc8 | #6d5e47 | - |
| Hover | #f5ede3 | 1px #d4a574 | #6d5e47 | - |
| Pressed | #f5ede3 | 1px #d4a574 | #6d5e47 | scale: 0.96 |
| Disabled | transparent | 1px #e8dfc8 | #a0896b | opacity: 0.6 |

**图标按钮（Icon Button）**：

| 状态 | 背景色 | 边框 | 其他效果 |
|------|--------|------|----------|
| Normal | transparent | 无 | - |
| Hover | #f5ede3 | 1px #e8dfc8 | - |
| Pressed | #f5ede3 | 1px #e8dfc8 | scale: 0.92 |

**动画规范**：
- 颜色过渡：180ms, Easing.OutQuad
- 缩放过渡：150ms, Easing.OutQuad
- 边框过渡：180ms, Easing.OutQuad

**示例代码**：

```qml
// 主按钮
Button {
    id: primaryButton
    
    background: Rectangle {
        color: {
            if (primaryButton.pressed) return "#c99666"
            if (primaryButton.hovered) return "#d9a574"
            return "#d4a574"
        }
        radius: 6
        border.color: primaryButton.hovered ? "#c99666" : "transparent"
        border.width: primaryButton.hovered ? 1 : 0
        
        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: primaryButton.text
        color: "#fffef9"
        font.pixelSize: 15
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        scale: primaryButton.pressed ? 0.96 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }
    }
}
```

### 4.2 卡片和容器的 hover 状态

为卡片和可交互容器添加悬停反馈：

**TaskItem 悬停状态**：

| 状态 | 背景色 | 边框色 | 边框宽度 | 阴影 |
|------|--------|--------|----------|------|
| Normal | #faf6ee | #e8dfc8 | 1px | Level 1 |
| Hover | #fffef9 | #d4a574 | 1.5px | Level 1 |
| Completed | - | - | - | opacity: 0.70 |

**日历单元格悬停状态**：

| 状态 | 背景色 | 边框色 | 边框宽度 |
|------|--------|--------|----------|
| Normal | transparent | transparent | 0 |
| Hover | #faf8f3 | #e8dfc8 | 1px |
| Selected | #f5ede3 | #d4a574 | 2px |
| Today | #f5ede3 | #d4a574 | 2px |

**动画规范**：
- 所有过渡使用 180ms, Easing.OutQuad
- 使用 Behavior on color/border.color/border.width

**示例代码**：

```qml
Rectangle {
    id: card
    color: mouseArea.containsMouse ? "#fffef9" : "#faf6ee"
    border.color: mouseArea.containsMouse ? "#d4a574" : "#e8dfc8"
    border.width: mouseArea.containsMouse ? 1.5 : 1
    
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
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
    }
}
```

### 4.3 输入框和下拉框状态

**TextField 状态系统**：

| 状态 | 背景色 | 边框色 | 边框宽度 | 焦点环 |
|------|--------|--------|----------|--------|
| Normal | #faf8f3 | #e8dfc8 | 1px | 无 |
| Hover | #faf8f3 | #d4a574 | 1px | 无 |
| Focus | #faf8f3 | #d4a574 | 2px | 有（#30d4a574） |
| Disabled | #f5ede3 | #e8dfc8 | 1px | 无 |

**ComboBox 状态系统**：

| 状态 | 背景色 | 边框色 | 边框宽度 | 箭头 |
|------|--------|--------|----------|------|
| Normal | #faf8f3 | #e8dfc8 | 1px | ▼ 0° |
| Hover | #f5ede3 | #e8dfc8 | 1px | ▼ 0° |
| Open | #f5ede3 | #d4a574 | 2px | ▼ 180° |

**动画规范**：
- 边框过渡：200ms, Easing.OutQuad
- 焦点环出现：200ms, Easing.OutQuad
- 箭头旋转：200ms, Easing.OutQuad

**示例代码**：

```qml
TextField {
    id: textField
    
    background: Rectangle {
        color: "#faf8f3"
        radius: 6
        border.color: textField.activeFocus ? "#d4a574" : "#e8dfc8"
        border.width: textField.activeFocus ? 2 : 1
        
        Behavior on border.color {
            ColorAnimation { duration: 200; easing.type: Easing.OutQuad }
        }
        Behavior on border.width {
            NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
        }
        
        // 焦点环
        layer.enabled: textField.activeFocus
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

### 4.4 对话框打开/关闭动画

**AddTaskDialog 动画规范**：

| 阶段 | 时长 | 缓动曲线 | 效果 |
|------|------|----------|------|
| 打开 | 220ms | Easing.OutCubic | opacity: 0→1, scale: 0.94→1.0 |
| 关闭 | 220ms | Easing.InQuad | opacity: 1→0, scale: 1.0→0.94 |

**背景遮罩动画**：
- 打开：opacity 0→0.6, 220ms
- 关闭：opacity 0.6→0, 220ms

**示例代码**：

```qml
Dialog {
    id: dialog
    modal: true
    
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
}
```

---

## 5. 色彩层次层设计

### 5.1 色彩语义化

建立语义化的颜色系统，分为背景、边框、文本、强调、状态五个类别：

**背景色（Background）**：

| Token | 值 | 用途 |
|-------|-----|------|
| bg-primary | #fffef9 | 主背景（页面、卡片、对话框） |
| bg-secondary | #faf8f3 | 次级背景（侧边栏、输入框） |
| bg-tertiary | #faf6ee | 三级背景（TaskItem默认） |
| bg-hover | #f5ede3 | 悬停背景（按钮、卡片悬停） |
| bg-selected | #f0e6d2 | 选中背景（Sidebar激活项） |
| bg-disabled | #ebe6dd | 禁用背景 |

**边框色（Border）**：

| Token | 值 | 用途 |
|-------|-----|------|
| border-default | #e8dfc8 | 默认边框 |
| border-emphasis | #d4a574 | 强调边框（悬停、激活） |
| border-hover | #ddd4bb | 悬停边框（次要交互） |
| border-focus | #d4a574 | 聚焦边框 |

**文本色（Text）**：

| Token | 值 | 用途 | 对比度 |
|-------|-----|------|--------|
| text-primary | #3d3327 | 主文本（标题、任务标题） | AAA |
| text-secondary | #6d5e47 | 次级文本（描述、按钮） | AA |
| text-tertiary | #8b7355 | 三级文本（提示、标签） | AA |
| text-disabled | #a0896b | 禁用文本 | - |
| text-completed | #8b7355 | 完成任务文本 | AA |
| text-inverse | #fffef9 | 反色文本（主按钮） | AAA |

**强调色（Accent）**：

| Token | 值 | 用途 |
|-------|-----|------|
| accent-primary | #d4a574 | 主强调色（按钮、边框、选中） |
| accent-hover | #d9a574 | 悬停强调色 |
| accent-pressed | #c99666 | 按下强调色 |

**状态色（State）**：

| Token | 值 | 用途 |
|-------|-----|------|
| state-error | #b24f3d | 错误提示 |
| state-warning | #d4a574 | 警告提示 |
| state-success | #7a9d6f | 成功提示（预留） |
| state-info | #6d8aa5 | 信息提示（预留） |

### 5.2 对比度优化

确保所有文本符合WCAG 2.1无障碍标准：

**对比度要求**：

| 场景 | 最小对比度 | 推荐对比度 | 当前实现 |
|------|-----------|-----------|----------|
| 大文本（≥18px或14px加粗） | 3:1 (AA) | 4.5:1 (AAA) | ✅ |
| 正文文本（<18px） | 4.5:1 (AA) | 7:1 (AAA) | ✅ |
| 装饰性文本 | 无要求 | - | - |

**关键调整**：

1. **TodayTaskView描述文字**：
   - 从 #8b7355 调整为 #6d5e47
   - 提升对比度从 3.2:1 到 4.8:1

2. **完成任务文本**：
   - 颜色：#8b7355
   - 透明度：从 0.62 提升到 0.70
   - 有效对比度：3.5:1（大文本AA级）

3. **次要文本**：
   - 使用 #6d5e47 而非 #8b7355
   - 确保在 #fffef9 背景上达到 AA 级

### 5.3 分类色彩系统

为任务分类建立色彩系统（预留，当前未实现）：

| 分类 | 主色 | 浅色背景 | 用途 |
|------|------|----------|------|
| 工作 | #d4a574 | #f5ede3 | 工作相关任务 |
| 学习 | #7a9d6f | #e8f0e5 | 学习相关任务 |
| 生活 | #d9956e | #f5ede8 | 生活相关任务 |
| 其他 | #8b7355 | #f0ece6 | 其他类型任务 |

**应用场景**：
- 任务分类标签背景色
- 日历单元格任务指示器
- 统计图表分类颜色

### 5.4 视觉层级优化

通过颜色、字体、阴影建立清晰的视觉层级：

**层级1 - 关键信息**：
- 文本：#3d3327, 15-24px, Font.Bold/Font.Medium
- 背景：#fffef9
- 边框：#d4a574（激活状态）
- 阴影：Level 1-2
- 应用：任务标题、页面标题、统计数字

**层级2 - 次要信息**：
- 文本：#6d5e47, 13-15px, Font.Medium/Font.Normal
- 背景：#faf8f3
- 边框：#e8dfc8
- 阴影：Level 1
- 应用：描述文字、按钮文字、卡片内容

**层级3 - 辅助信息**：
- 文本：#8b7355, 12-13px, Font.Normal
- 背景：#faf6ee
- 边框：#e8dfc8
- 阴影：无
- 应用：提示文字、标签、时间戳

**层级4 - 弱化信息**：
- 文本：#a0896b, 12px, Font.Normal
- 透明度：0.6-0.7
- 应用：禁用状态、完成任务、次要提示

**实施原则**：

1. **同一层级使用相同的视觉权重**：相同重要性的元素使用相同的颜色和字体大小
2. **层级间对比明显**：相邻层级的颜色对比度至少为 1.5:1
3. **通过多维度强化层级**：不仅使用颜色，还结合字体大小、粗细、阴影
4. **避免过度使用强调色**：强调色（#d4a574）仅用于关键交互元素

**示例应用**：

```qml
// 层级1：页面标题
Text {
    text: "今日任务"
    font.pixelSize: 24
    font.weight: Font.Bold
    color: "#3d3327"
}

// 层级2：任务标题
Text {
    text: taskTitle
    font.pixelSize: 15
    font.weight: Font.Medium
    color: "#3d3327"
}

// 层级3：分类标签
Text {
    text: categoryName
    font.pixelSize: 12
    color: "#8b7355"
}

// 层级4：完成任务
Text {
    text: completedTaskTitle
    font.pixelSize: 15
    font.weight: Font.Medium
    color: "#8b7355"
    opacity: 0.70
}
```

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

