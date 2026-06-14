# 温暖主题视觉深化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通过纸张纹理、暖色阴影、按钮压感动画深化温暖主题氛围

**Architecture:** 主背景添加SVG噪点纹理，侧边栏使用渐变；卡片组件改用暖色阴影并添加悬停效果；TaskItem按钮添加下沉和阴影变化

**Tech Stack:** QML, MultiEffect, Gradient, Transform, Behavior, NumberAnimation

---

## 模块1：纸张纹理

### Task 1: 主背景添加纹理

**Files:**
- Modify: `qml/Main.qml`

- [ ] **Step 1: 在ApplicationWindow内添加纹理层Rectangle**

找到ApplicationWindow的定义，在MainWindow之前添加纹理层：

```qml
ApplicationWindow {
    id: root
    
    visible: true
    width: 1024
    height: 768
    minimumWidth: 860
    minimumHeight: 620
    title: "番茄Todo"
    color: "#fffef9"
    
    // 新增：纸张纹理层
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        z: -1
        
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

- [ ] **Step 2: 验证编译和运行**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
./build/TomatoTodo
```

预期结果：
- 应用启动成功
- 主背景有极微妙的纹理（几乎看不出，但增加质感）
- 不影响内容可读性

- [ ] **Step 3: 提交主背景纹理**

```bash
git add qml/Main.qml
git commit -m "feat(theme): add subtle paper texture to main background

- Add SVG noise texture layer with opacity 0.03
- Use data URI to avoid external file dependency
- Tile pattern across entire window
- Enhance warm paper theme atmosphere

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: 侧边栏添加渐变

**Files:**
- Modify: `qml/components/Sidebar.qml`

- [ ] **Step 1: 将Sidebar的color属性替换为gradient**

找到Sidebar的Rectangle定义，将color替换为gradient：

```qml
Rectangle {
    id: root
    
    width: 208
    // readonly property color sidebarBackgroundColor: "#faf8f3"
    // color: root.sidebarBackgroundColor  // 删除这行
    
    // 新增：渐变背景
    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: "#faf8f3" }
        GradientStop { position: 1.0; color: "#f5f0e6" }
    }
```

- [ ] **Step 2: 验证编译和运行**

```bash
cmake --build build
./build/TomatoTodo
```

预期：侧边栏顶部稍亮，底部稍暗，模拟光照

- [ ] **Step 3: 提交侧边栏渐变**

```bash
git add qml/components/Sidebar.qml
git commit -m "feat(theme): add vertical gradient to sidebar

- Replace solid color with vertical gradient
- Top: #faf8f3, Bottom: #f5f0e6
- Simulate light direction for paper-like depth

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3: StatCard暖色阴影

**Files:**
- Modify: `qml/components/StatCard.qml`

- [ ] **Step 1: 修改StatCard的shadowColor为暖棕色**

找到layer.effect MultiEffect，修改shadowColor：

```qml
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#5d4e37"      // 改为暖棕色
        shadowOpacity: 0.08
        shadowBlur: 0.18            // 稍微增加
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }
```

- [ ] **Step 2: 验证编译和运行**

```bash
cmake --build build
./build/TomatoTodo
```

- [ ] **Step 3: 提交StatCard暖色阴影**

```bash
git add qml/components/StatCard.qml
git commit -m "feat(theme): use warm shadow color for StatCard

- Change shadowColor from black to warm brown #5d4e37
- Increase shadowBlur from 0.14 to 0.18
- Enhance warm paper theme consistency

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 4: TaskItem暖色阴影和悬停效果

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 修改TaskItem的shadowColor**

找到layer.effect，修改shadowColor：

```qml
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#5d4e37"      // 改为暖棕色
        shadowOpacity: root.itemHovered ? 0.12 : 0.08
        shadowBlur: root.itemHovered ? 0.25 : 0.18
        shadowHorizontalOffset: 0
        shadowVerticalOffset: root.itemHovered ? 6 : 2
    }
```

- [ ] **Step 2: 添加阴影属性的Behavior（如果MultiEffect支持）**

注意：MultiEffect的属性可能不支持Behavior，如不支持则跳过此步骤。

- [ ] **Step 3: 验证悬停效果**

```bash
./build/TomatoTodo
```

测试：鼠标悬停任务卡片，阴影应增强（"抬起"效果）

- [ ] **Step 4: 提交TaskItem暖色阴影**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(theme): add warm shadow and hover effect to TaskItem

- Use warm brown shadow #5d4e37
- Increase shadow on hover (lift effect)
- shadowOpacity: 0.08 -> 0.12
- shadowBlur: 0.18 -> 0.25
- shadowVerticalOffset: 2 -> 6

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5-6: TaskItem按钮压感动画

由于按钮改动较复杂且重复性高，合并为一个任务：

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 找到focusButton的background，添加下沉动画**

在focusButton的background Rectangle中添加transform：

```qml
        transform: Translate {
            y: focusButton.pressed ? 1 : 0
            
            Behavior on y {
                NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
            }
        }
```

- [ ] **Step 2: 修改focusButton的contentItem添加缩放**

```qml
        scale: focusButton.pressed ? 0.98 : 1.0
        
        Behavior on scale {
            NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
        }
```

- [ ] **Step 3: 对deleteButton应用相同的改动**

重复Step 1-2的修改到deleteButton

- [ ] **Step 4: 验证按钮压感效果**

```bash
./build/TomatoTodo
```

测试：点击"开始专注"和"删除"按钮，应有微妙的下沉感

- [ ] **Step 5: 提交按钮压感动画**

```bash
git add qml/components/TaskItem.qml
git commit -m "feat(theme): add press animation to TaskItem buttons

- Add 1px downward translate on press
- Add 0.98 scale to button text
- Duration: 90ms with OutQuad easing
- Simulate paper press tactile feedback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 7: 完整功能测试和提交

**Files:**
- All modified files

- [ ] **Step 1: 模块1测试（纹理）**

测试清单：
- 主背景纹理几乎不可见但有质感
- 侧边栏渐变自然
- 不影响内容可读性

- [ ] **Step 2: 模块2测试（阴影）**

测试清单：
- 卡片阴影呈暖棕色
- 悬停时卡片"抬起"
- 阴影过渡流畅

- [ ] **Step 3: 模块3测试（按钮）**

测试清单：
- 按钮按下时1px下沉
- 文字同步缩放
- 动画快速响应

- [ ] **Step 4: 整体协调测试**

测试清单：
- 三个模块效果和谐统一
- 温暖氛围明显增强但不过度
- 所有动画使用统一缓动
- 性能无明显影响

- [ ] **Step 5: 最终提交（如有遗漏）**

```bash
git add qml/Main.qml qml/components/Sidebar.qml qml/components/StatCard.qml qml/components/TaskItem.qml
git commit -m "feat(theme): complete warm theme visual enhancement

Three modules implemented:
1. Paper texture: SVG noise on main bg, gradient on sidebar
2. Warm shadows: brown #5d4e37 with hover lift effect
3. Button press: 1px sink with 0.98 scale

Result: Enhanced warm paper atmosphere while maintaining
usability and performance

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 完成检查清单

- [ ] 主背景纹理微妙自然
- [ ] 侧边栏渐变模拟光照
- [ ] 所有卡片使用暖色阴影
- [ ] 悬停效果流畅
- [ ] 按钮压感动画快速响应
- [ ] 所有模块可独立回滚
- [ ] 性能测试通过
- [ ] 所有代码已提交

## 模块2：纸质投影

### Task 3: StatCard暖色阴影

**Files:**
- Modify: `qml/components/StatCard.qml`

### Task 4: TaskItem暖色阴影和悬停效果

**Files:**
- Modify: `qml/components/TaskItem.qml`

## 模块3：按钮压感

### Task 5: TaskItem按钮压感动画 - 开始专注按钮

**Files:**
- Modify: `qml/components/TaskItem.qml`

### Task 6: TaskItem按钮压感动画 - 删除按钮

**Files:**
- Modify: `qml/components/TaskItem.qml`

## 测试与验收

### Task 7: 完整功能测试和提交

**Files:**
- All modified files
