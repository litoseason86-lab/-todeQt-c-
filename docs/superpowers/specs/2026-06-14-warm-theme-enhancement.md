# 温暖主题视觉深化设计文档

**版本**: 1.0  
**日期**: 2026-06-14  
**状态**: 设计阶段

---

## 1. 概述

### 1.1 功能描述

通过添加微妙的纸张纹理和暖色纸质投影，深化番茄Todo的温暖主题氛围。所有效果都极其克制，用户应该"感觉"到温暖，而不是"看到"特效。包含三个核心改进：纸张纹理背景、纸质阴影系统、按钮压感动画。

### 1.2 设计目标

- **增强质感**：消除纯色背景的"塑料感"，增加真实纸张的触感
- **强化主题**：通过暖色阴影和光影细节，加深温暖纸质的心理暗示
- **提升交互**：按钮压感动画模拟纸张按压，增加交互趣味性
- **保持克制**：所有效果微妙自然，不干扰内容和可读性

### 1.3 设计原则

- **微妙优先**：纹理几乎不可见（opacity: 0.03），阴影柔和
- **暖色系**：阴影使用 `rgba(93, 78, 55, ...)` 而非纯黑色
- **性能友好**：纯CSS实现，无额外图片资源，不影响渲染性能
- **统一性**：所有动画使用 `Easing.OutQuad` 缓动，保持一致体验

---

## 2. 纸张纹理设计

### 2.1 纹理方案

**方案选择：CSS渐变 + SVG噪点**

使用极细的SVG噪点纹理叠加在背景上，模拟纸张的细微不平整。

**SVG噪点纹理**：

```qml
Rectangle {
    color: "#fffef9"
    
    // 添加噪点纹理
    Image {
        anchors.fill: parent
        source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='noise'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23noise)'/></svg>"
        opacity: 0.03  // 极低透明度，几乎不可见
        fillMode: Image.Tile
    }
}
```

**替代方案：轻微渐变**

如果SVG噪点在某些设备上性能不佳，可使用纯CSS渐变：

```qml
Rectangle {
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: "#fffef9" }
        GradientStop { position: 1.0; color: "#faf8f3" }
    }
}
```

### 2.2 应用范围

**应用纹理的区域**：

1. **主背景**（`qml/Main.qml`）：
   - 颜色：`#fffef9`
   - 纹理：SVG噪点，opacity: 0.03

2. **侧边栏背景**（`qml/components/Sidebar.qml`）：
   - 颜色：`#faf8f3`
   - 纹理：垂直渐变（从 `#faf8f3` 到 `#f5f0e6`）
   - 效果：顶部稍亮，底部稍暗，模拟光照

**不应用纹理的区域**：

- 卡片内部（保持纯色 `#fffef9`，确保内容可读性）
- 按钮（保持纯色，确保交互清晰）
- 文字区域（避免干扰阅读）

---

## 3. 纸质投影设计

### 3.1 阴影方案

**现有阴影**（MultiEffect）：

```qml
layer.effect: MultiEffect {
    shadowColor: "#000000"
    shadowOpacity: 0.08
    shadowBlur: 0.14
    shadowVerticalOffset: 2
}
```

**改进后的纸质阴影**：

使用多层box-shadow模拟纸张厚度和暖色氛围：

```qml
// 方案A：使用自定义Rectangle叠加多层阴影
Rectangle {
    id: shadowLayer
    anchors.fill: parent
    anchors.margins: -8
    z: -1
    color: "transparent"
    
    // 第一层：近景阴影（边缘清晰）
    Rectangle {
        anchors.fill: parent
        anchors.margins: 8
        radius: 8
        color: "transparent"
        border.width: 0
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowColor: "#5d4e37"
            shadowOpacity: 0.06
            shadowBlur: 0.08
            shadowVerticalOffset: 1
        }
    }
    
    // 第二层：远景阴影（柔和扩散）
    Rectangle {
        anchors.fill: parent
        anchors.margins: 8
        radius: 8
        color: "transparent"
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowColor: "#5d4e37"
            shadowOpacity: 0.04
            shadowBlur: 0.3
            shadowVerticalOffset: 4
        }
    }
}
```

**简化方案（推荐）**：

如果多层阴影性能开销过大，使用单层暖色阴影：

```qml
layer.effect: MultiEffect {
    shadowEnabled: true
    shadowColor: "#5d4e37"      // 暖棕色替代纯黑
    shadowOpacity: 0.08
    shadowBlur: 0.18            // 稍微增加模糊半径
    shadowHorizontalOffset: 0
    shadowVerticalOffset: 2
}
```

### 3.2 悬停效果

**卡片悬停时的"抬起"效果**：

```qml
Rectangle {
    id: card
    
    property bool isHovered: hoverArea.containsMouse
    
    // 阴影随悬停状态变化
    layer.effect: MultiEffect {
        shadowColor: "#5d4e37"
        shadowOpacity: card.isHovered ? 0.12 : 0.08
        shadowBlur: card.isHovered ? 0.25 : 0.18
        shadowVerticalOffset: card.isHovered ? 6 : 2
    }
    
    // 平滑过渡
    Behavior on layer.effect.shadowOpacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
    }
    Behavior on layer.effect.shadowBlur {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
    }
    Behavior on layer.effect.shadowVerticalOffset {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
    }
    
    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }
}
```

**应用范围**：

- TaskItem 卡片
- StatCard 统计卡片
- 其他浮动卡片组件

**不应用悬停效果的区域**：

- 侧边栏（无悬停抬起）
- 主背景（无阴影）
- 按钮（使用压感动画，不用抬起）

---

## 4. 纸张压感动画

### 4.1 按钮交互

**"纸张按压"效果设计**：

按钮按下时，模拟纸张被轻微压下的触感：

```qml
Button {
    id: btn
    
    background: Rectangle {
        color: btn.pressed ? "#b9854f" : (btn.hovered ? "#c8955f" : "#d4a574")
        radius: 6
        
        // 按下时轻微下沉
        transform: Translate {
            y: btn.pressed ? 1 : 0
        }
        
        // 阴影随按压缩小
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowColor: "#5d4e37"
            shadowOpacity: btn.pressed ? 0.04 : 0.08
            shadowBlur: btn.pressed ? 0.1 : 0.14
            shadowVerticalOffset: btn.pressed ? 1 : 2
        }
        
        Behavior on y {
            NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
        }
    }
    
    contentItem: Text {
        text: btn.text
        color: "#fffef9"
        scale: btn.pressed ? 0.98 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
        }
    }
}
```

### 4.2 动画参数

**按压效果参数**：

- **下沉距离**：1px（微妙，不明显）
- **缩放比例**：0.98倍（文字轻微收缩）
- **阴影变化**：
  - 透明度：0.08 → 0.04（减半）
  - 模糊半径：0.14 → 0.1（缩小）
  - 垂直偏移：2px → 1px（靠近）
- **动画时长**：90ms（快速响应）
- **缓动函数**：Easing.OutQuad（柔和）

**应用范围（只改动高频按钮）**：

1. **TaskItem 中的按钮**：
   - "开始专注"按钮（focusButton）
   - "删除"按钮（deleteButton）

2. **不改动的按钮**：
   - 侧边栏项（使用颜色变化，不用压感）
   - AddTaskDialog 中的按钮（低频，保持现状）
   - 其他对话框按钮（避免过度重构）

**理由**：
- TaskItem 按钮是用户最高频交互的按钮
- 集中改动单一文件，降低风险
- 其他按钮保持现有交互，避免不一致

---

## 5. 技术实现

### 5.1 纹理实现

**Main.qml 主背景纹理**：

```qml
ApplicationWindow {
    id: root
    color: "#fffef9"
    
    // 添加纹理层
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        z: -1  // 在所有内容之下
        
        Image {
            anchors.fill: parent
            source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='noise'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23noise)'/></svg>"
            opacity: 0.03
            fillMode: Image.Tile
        }
    }
    
    MainWindow {
        anchors.fill: parent
    }
}
```

**Sidebar.qml 渐变背景**：

```qml
Rectangle {
    id: root
    width: 208
    
    // 替换纯色为渐变
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: "#faf8f3" }
        GradientStop { position: 1.0; color: "#f5f0e6" }
    }
    
    // ... 现有内容 ...
}
```

### 5.2 阴影实现

**StatCard.qml 暖色阴影**：

```qml
Rectangle {
    id: root
    
    // 修改现有 MultiEffect
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#5d4e37"      // 改为暖棕色
        shadowOpacity: 0.08
        shadowBlur: 0.18            // 稍微增加
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }
    
    // ... 现有内容 ...
}
```

**TaskItem.qml 暖色阴影 + 悬停效果**：

```qml
Rectangle {
    id: root
    
    // 添加悬停状态属性
    readonly property bool itemHovered: hoverArea.containsMouse
    
    // 修改阴影
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#5d4e37"
        shadowOpacity: root.itemHovered ? 0.12 : 0.08
        shadowBlur: root.itemHovered ? 0.25 : 0.18
        shadowHorizontalOffset: 0
        shadowVerticalOffset: root.itemHovered ? 6 : 2
    }
    
    // 添加阴影过渡动画
    Behavior on layer.effect.shadowOpacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
    }
    Behavior on layer.effect.shadowBlur {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
    }
    Behavior on layer.effect.shadowVerticalOffset {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
    }
}
```

**注意**：MultiEffect 的属性可能无法直接添加 Behavior。如果不支持，需要使用状态机或手动动画。

### 5.3 动画实现

**TaskItem.qml 按钮压感**：

找到 focusButton 和 deleteButton，为其 background 添加压感效果：

```qml
Button {
    id: focusButton
    
    background: Rectangle {
        radius: 6
        color: {
            if (!focusButton.enabled) return "#e8dfc8"
            if (focusButton.pressed) return "#b9854f"
            if (focusButton.hovered) return "#c8955f"
            return "#d4a574"
        }
        
        // 新增：按下时下沉
        transform: Translate {
            y: focusButton.pressed ? 1 : 0
            
            Behavior on y {
                NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
            }
        }
        
        // 新增：阴影变化
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#5d4e37"
            shadowOpacity: focusButton.pressed ? 0.04 : 0.08
            shadowBlur: focusButton.pressed ? 0.1 : 0.14
            shadowVerticalOffset: focusButton.pressed ? 1 : 2
        }
        
        // 保留现有颜色过渡
        Behavior on color {
            ColorAnimation {
                duration: 160
                easing.type: Easing.OutQuad
            }
        }
    }
    
    contentItem: Text {
        text: focusButton.text
        color: focusButton.enabled ? "#fffef9" : "#a0896b"
        font.pixelSize: 13
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        
        // 修改：按下时微缩
        scale: focusButton.pressed ? 0.98 : 1.0
        transformOrigin: Item.Center
        
        Behavior on scale {
            NumberAnimation {
                duration: 90
                easing.type: Easing.OutQuad
            }
        }
    }
}

// deleteButton 同理修改
```

---

## 6. 测试策略

### 6.1 纹理测试

- [ ] 主背景纹理几乎不可见，不干扰内容阅读
- [ ] 侧边栏渐变自然，无明显色带
- [ ] 纹理在不同分辨率下表现一致
- [ ] 纹理不影响性能（帧率稳定60fps）

### 6.2 阴影测试

- [ ] 暖色阴影柔和自然，无硬边
- [ ] 卡片悬停时"抬起"效果流畅
- [ ] 阴影不溢出卡片边界
- [ ] 阴影过渡动画平滑（200ms）
- [ ] 多个卡片阴影一致性

### 6.3 按钮压感测试

- [ ] 按钮按下时1px下沉可感知
- [ ] 文字缩放到0.98倍协调
- [ ] 阴影缩小效果自然
- [ ] 动画时长90ms响应快速
- [ ] 连续快速点击不卡顿
- [ ] 只有TaskItem按钮有压感，其他按钮保持原样

### 6.4 整体协调测试

- [ ] 纹理 + 阴影 + 压感效果和谐统一
- [ ] 温暖氛围增强但不过度
- [ ] 所有动画使用统一的Easing.OutQuad
- [ ] 不影响现有功能和交互

### 6.5 性能测试

- [ ] SVG纹理不影响渲染性能
- [ ] 多层阴影（如果使用）无明显性能下降
- [ ] 动画过渡流畅，帧率稳定
- [ ] 内存占用无异常增长

---

## 7. 实施计划概要

本功能分为3个独立模块，可以分阶段实施：

### 模块1：纸张纹理（优先级：高）

- 在Main.qml添加SVG噪点纹理层
- 在Sidebar.qml替换纯色为渐变
- 验证纹理效果和性能
- 如有性能问题，切换为纯CSS渐变

### 模块2：纸质投影（优先级：高）

- 修改StatCard.qml阴影为暖色
- 修改TaskItem.qml阴影为暖色
- 添加TaskItem悬停"抬起"效果
- 测试阴影过渡动画

### 模块3：按钮压感（优先级：中）

- 修改TaskItem中focusButton的背景和contentItem
- 修改TaskItem中deleteButton的背景和contentItem
- 添加下沉动画和阴影变化
- 测试按压交互反馈

**实施顺序建议**：
1. 先实施模块1和2（纹理+阴影），验证整体氛围效果
2. 如果效果满意，再实施模块3（按钮压感）
3. 每个模块独立提交，便于回滚

---

## 8. 文件清单

### 修改文件

- `qml/Main.qml` - 添加主背景纹理层
- `qml/components/Sidebar.qml` - 渐变背景
- `qml/components/StatCard.qml` - 暖色阴影
- `qml/components/TaskItem.qml` - 暖色阴影 + 悬停效果 + 按钮压感

### 无需新建文件

所有功能通过修改现有文件实现

---

## 附录：效果对比

### 纹理效果对比

| 区域 | 修改前 | 修改后 |
|------|--------|--------|
| 主背景 | 纯色 #fffef9 | #fffef9 + SVG噪点(opacity:0.03) |
| 侧边栏 | 纯色 #faf8f3 | 垂直渐变 #faf8f3→#f5f0e6 |

### 阴影效果对比

| 属性 | 修改前 | 修改后 |
|------|--------|--------|
| 阴影颜色 | #000000（纯黑） | #5d4e37（暖棕色） |
| 阴影透明度 | 0.08 | 0.08（普通）/ 0.12（悬停） |
| 阴影模糊 | 0.14 | 0.18（普通）/ 0.25（悬停） |
| 垂直偏移 | 2px | 2px（普通）/ 6px（悬停） |

### 按钮压感对比

| 状态 | 修改前 | 修改后 |
|------|--------|--------|
| 按下位置 | 无变化 | 下沉1px |
| 按下缩放 | 0.96倍 | 0.98倍（更微妙） |
| 按下阴影 | 无变化 | 透明度减半、偏移缩小 |

---

## 设计理念总结

**核心理念**：用户应该"感觉"到温暖，而不是"看到"特效

- 纹理：opacity 0.03，几乎隐形
- 阴影：暖色替代黑色，传递温暖而非冷硬
- 压感：1px下沉，微妙但可感知
- 动画：90-200ms，快速响应不拖沓

**与温暖纸质主题的契合**：

- 纹理模拟纸张表面的不平整
- 暖色阴影模拟纸张在温暖光源下的投影
- 压感动画模拟手指按压纸张的触感

所有效果叠加后，整体氛围更加温暖真实，但不会喧宾夺主。
