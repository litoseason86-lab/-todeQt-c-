# 月度专注记录功能实施计划 - Part 3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 改造日历显示每日总时长，实现专注记录时间轴组件，完善所有交互和样式

**Architecture:** 修改日历格子显示dailyTotals数据，创建新的时间轴组件展示selectedDaySessions，应用温暖纸质主题配色

**Tech Stack:** QML, Qt Quick Components, 设计系统配色方案

---

## Task 8: 改造日历显示逻辑

**Files:**
- Modify: `qml/views/MonthGoalView.qml`

- [ ] **Step 1: 找到日历格子的代码位置**

```bash
grep -n "Repeater\|Rectangle.*day\|Text.*dayNumber" qml/views/MonthGoalView.qml | head -20
```

这帮助我们定位日历格子的实现位置

- [ ] **Step 2: 修改日历格子布局 - 添加容器结构**

找到日历格子的Rectangle（通常在Repeater内部），确保其结构为：

```qml
Rectangle {
    id: dayCell
    width: (parent.width - 6 * 8) / 7  // 7列，间距8px
    height: 58
    radius: 6
    color: {
        if (isSelected) return "#f0e6d2";
        if (mouseArea.containsMouse) return "#fffef9";
        return "#faf6ee";
    }
    border.width: isSelected ? 2 : 1
    border.color: isSelected ? "#d4a574" : (mouseArea.containsMouse ? "#d4a574" : "#e8dfc8")
    
    // 内容稍后添加
}
```

- [ ] **Step 3: 添加日期数字显示 - 第一个模块**

在dayCell的Rectangle内部，添加日期数字：

```qml
    Column {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 4
        
        Text {
            id: dayNumberText
            text: dayNumber
            font.pixelSize: 13
            font.weight: Font.Bold
            color: isCurrentMonth ? "#5d4e37" : "#c4b5a0"
            horizontalAlignment: Text.AlignLeft
        }
        
        // 时长文字稍后添加
    }
```

- [ ] **Step 4: 添加专注时长显示 - 第二个模块**

在dayNumberText下方添加时长显示：

```qml
        Text {
            id: durationText
            visible: {
                var dateStr = Qt.formatDate(
                    new Date(currentYear, currentMonth - 1, dayNumber),
                    "yyyy-MM-dd"
                );
                return dailyTotals[dateStr] && dailyTotals[dateStr] > 0;
            }
            text: {
                var dateStr = Qt.formatDate(
                    new Date(currentYear, currentMonth - 1, dayNumber),
                    "yyyy-MM-dd"
                );
                var seconds = dailyTotals[dateStr] || 0;
                return focusHistoryService.formatDuration(seconds);
            }
            font.pixelSize: 11
            font.weight: Font.Medium
            color: "#d4a574"
            horizontalAlignment: Text.AlignLeft
            width: parent.width
            elide: Text.ElideRight
        }
```

- [ ] **Step 5: 添加鼠标交互区域 - 第三个模块**

在dayCell的Rectangle内部（Column外部）添加：

```qml
    property bool isSelected: selectedDay === dayNumber && isCurrentMonth
    
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        
        onClicked: {
            if (isCurrentMonth) {
                selectedDay = dayNumber;
                updateSelectedDaySessions();
            }
        }
    }
```

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 7: 运行应用验证日历显示**

```bash
./build/TomatoTodo
```

手动测试：
- 打开专注历史页面
- 日历格子应该显示日期数字（上方）
- 有专注记录的日期应该在下方显示总时长（如"3.7小时"）
- 鼠标悬停应该改变边框颜色
- 点击日期应该高亮选中

- [ ] **Step 8: 提交日历显示改造**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "feat: update calendar to display daily focus duration

- Add Column layout with date number and duration text
- Display formatted duration from dailyTotals
- Apply warm theme colors (#d4a574 for duration)
- Update hover and selected states styling

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: 实现时间轴组件

**Files:**
- Modify: `qml/views/MonthGoalView.qml`

- [ ] **Step 1: 创建时间轴容器 - 框架结构**

在日历下方（原来任务详情面板的位置），添加时间轴容器：

```qml
        // 专注记录时间轴
        Rectangle {
            id: timelinePanel
            width: parent.width
            height: 400
            color: "#fffef9"
            border.width: 1
            border.color: "#e8dfc8"
            radius: 8
            
            Column {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 16
                
                // 标题稍后添加
                // 时间轴列表稍后添加
            }
        }
```

- [ ] **Step 2: 添加时间轴标题 - 第一个模块**

在Column内部添加标题：

```qml
                Text {
                    id: timelineTitle
                    text: {
                        var date = new Date(currentYear, currentMonth - 1, selectedDay);
                        return currentMonth + "月" + selectedDay + "日 专注记录";
                    }
                    font.pixelSize: 16
                    font.weight: Font.Bold
                    color: "#5d4e37"
                }
```

- [ ] **Step 3: 添加空状态显示 - 第二个模块**

在标题下方添加空状态：

```qml
                Text {
                    id: emptyState
                    visible: selectedDaySessions.length === 0
                    text: "这一天还没有专注记录"
                    font.pixelSize: 13
                    color: "#8b7355"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
```

- [ ] **Step 4: 添加时间轴列表容器 - 第三个模块**

在空状态下方添加滚动列表：

```qml
                ScrollView {
                    id: timelineScrollView
                    width: parent.width
                    height: parent.height - timelineTitle.height - 32
                    visible: selectedDaySessions.length > 0
                    clip: true
                    
                    Column {
                        id: timelineColumn
                        width: parent.width
                        spacing: 20
                        
                        Repeater {
                            model: selectedDaySessions
                            
                            delegate: Rectangle {
                                // 时间轴条目稍后添加
                            }
                        }
                    }
                }
```

- [ ] **Step 5: 实现时间轴条目卡片 - 第四个模块**

在Repeater的delegate中实现完整的时间轴条目：

```qml
                            delegate: Rectangle {
                                id: sessionCard
                                width: timelineColumn.width - 24  // 留出左侧时间轴线的空间
                                height: cardContent.height + 24
                                color: "#faf8f3"
                                border.width: 1
                                border.color: "#e8dfc8"
                                radius: 6
                                x: 24  // 左侧留出时间轴线的空间
                                
                                // 时间轴圆点
                                Rectangle {
                                    id: timelineDot
                                    width: 10
                                    height: 10
                                    radius: 5
                                    color: "#d4a574"
                                    border.width: 2
                                    border.color: "#fffef9"
                                    anchors.left: parent.left
                                    anchors.leftMargin: -19  // 定位到左侧时间轴线上
                                    anchors.top: parent.top
                                    anchors.topMargin: 16
                                }
                                
                                // 时间轴线（除了最后一个条目）
                                Rectangle {
                                    visible: index < selectedDaySessions.length - 1
                                    width: 2
                                    height: 20  // 延伸到下一个卡片
                                    color: "#e8dfc8"
                                    anchors.left: parent.left
                                    anchors.leftMargin: -15
                                    anchors.top: timelineDot.bottom
                                    anchors.topMargin: 0
                                }
                                
                                // 卡片内容
                                Item {
                                    id: cardContent
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    height: contentRow.height
                                    
                                    Row {
                                        id: contentRow
                                        width: parent.width
                                        spacing: 12
                                        
                                        // 左侧：任务名称和时间段
                                        Column {
                                            width: parent.width * 0.65
                                            spacing: 4
                                            
                                            Text {
                                                text: modelData.taskTitle
                                                font.pixelSize: 15
                                                font.weight: Font.Medium
                                                color: "#3d3327"
                                                width: parent.width
                                                elide: Text.ElideRight
                                            }
                                            
                                            Text {
                                                text: {
                                                    var start = new Date(modelData.startTime);
                                                    var end = new Date(modelData.endTime);
                                                    var startStr = Qt.formatTime(start, "HH:mm");
                                                    var endStr = Qt.formatTime(end, "HH:mm");
                                                    return startStr + " - " + endStr;
                                                }
                                                font.pixelSize: 12
                                                color: "#8b7355"
                                            }
                                        }
                                        
                                        // 右侧：时长和状态
                                        Column {
                                            width: parent.width * 0.35 - 12
                                            spacing: 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            
                                            Text {
                                                text: focusHistoryService.formatDuration(modelData.durationSeconds)
                                                font.pixelSize: 18
                                                font.weight: Font.Bold
                                                color: "#d4a574"
                                                horizontalAlignment: Text.AlignRight
                                                width: parent.width
                                            }
                                            
                                            Text {
                                                text: "已完成"
                                                font.pixelSize: 11
                                                font.weight: Font.Medium
                                                color: "#4caf50"
                                                horizontalAlignment: Text.AlignRight
                                                width: parent.width
                                            }
                                        }
                                    }
                                }
                            }
```

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 7: 运行应用验证时间轴显示**

```bash
./build/TomatoTodo
```

手动测试：
- 打开专注历史页面
- 选择有专注记录的日期
- 应该显示时间轴，包含：
  - 标题显示选中日期
  - 时间轴线和圆点
  - 每条记录的卡片
  - 任务名称、时间段、时长、状态
- 选择无记录的日期应显示"这一天还没有专注记录"

- [ ] **Step 8: 调整时间轴样式细节**

微调间距和对齐：

```qml
// 如果时间轴线和圆点位置不对，调整这些值：
// timelineDot.anchors.leftMargin: -19
// timelineLine.anchors.leftMargin: -15
// sessionCard.x: 24
```

- [ ] **Step 9: 提交时间轴组件实现**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "feat: implement focus session timeline component

- Add timeline panel with date-specific title
- Implement empty state for days without sessions
- Create timeline cards with dot and line decorations
- Display task title, time range, duration, and status
- Apply warm theme colors throughout
- Support scrolling for multiple sessions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: 完善交互和样式

**Files:**
- Modify: `qml/views/MonthGoalView.qml`
- Modify: `qml/components/Sidebar.qml` (可选)

- [ ] **Step 1: 优化日历和时间轴的间距**

调整timelinePanel与日历的间距：

```qml
        // 在日历Rectangle和timelinePanel之间添加间距
        Item { width: 1; height: 16 }  // 垂直间距
```

- [ ] **Step 2: 添加平滑滚动动画**

在ScrollView中添加滚动行为：

```qml
                ScrollView {
                    id: timelineScrollView
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    
                    Behavior on contentY {
                        NumberAnimation {
                            duration: 200
                            easing.type: Easing.OutQuad
                        }
                    }
                    
                    // ... 其余代码
                }
```

- [ ] **Step 3: 添加日期选择动画效果**

为selectedDay变化添加过渡动画：

```qml
    Behavior on selectedDay {
        NumberAnimation {
            duration: 150
            easing.type: Easing.OutQuad
        }
    }
```

- [ ] **Step 4: 优化月份标题显示**

确保月份标题显示格式正确：

```qml
        Text {
            text: currentYear + "年" + currentMonth + "月"
            font.pixelSize: 13
            color: "#8b7355"
        }
```

- [ ] **Step 5: 添加加载状态指示（可选）**

在refresh()函数中添加加载状态：

```qml
    property bool isLoading: false
    
    function refresh() {
        isLoading = true;
        console.log("Refreshing focus history for", currentYear, currentMonth);
        
        monthSessions = focusHistoryService.getMonthSessions(currentYear, currentMonth);
        console.log("Loaded", monthSessions.length, "sessions");
        
        calculateDailyTotals();
        updateSelectedDaySessions();
        
        isLoading = false;
    }
```

然后在UI中使用：

```qml
        Text {
            visible: isLoading
            text: "加载中..."
            font.pixelSize: 13
            color: "#8b7355"
            anchors.centerIn: parent
        }
```

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 7: 运行完整功能测试**

```bash
./build/TomatoTodo
```

手动测试完整流程：
1. 打开专注历史页面
2. 验证本月日历显示正确
3. 有专注记录的日期显示总时长
4. 点击不同日期，时间轴正确更新
5. 时间轴显示任务名称、时间段、时长
6. 切换到上月、下月，数据正确刷新
7. 点击"本月"按钮返回当前月份
8. 所有颜色符合温暖纸质主题

- [ ] **Step 8: 移除调试日志**

移除之前添加的console.log语句：

```qml
    function refresh() {
        // console.log("Refreshing focus history for", currentYear, currentMonth);  // 删除
        monthSessions = focusHistoryService.getMonthSessions(currentYear, currentMonth);
        // console.log("Loaded", monthSessions.length, "sessions");  // 删除
        
        calculateDailyTotals();
        // console.log("Daily totals:", JSON.stringify(dailyTotals));  // 删除
        
        updateSelectedDaySessions();
    }
```

- [ ] **Step 9: 提交交互和样式优化**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "polish: improve interactions and styling

- Add spacing between calendar and timeline
- Add smooth scroll animation to timeline
- Add selection transition animation
- Optimize month title display format
- Remove debug console logs
- Final styling adjustments

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 10: (可选) 更新侧边栏入口文案**

如果需要，修改Sidebar.qml中的入口文案：

```bash
grep -n "月度目标" qml/components/Sidebar.qml
```

找到对应位置，将 "月度目标" 改为 "专注历史"

- [ ] **Step 11: (可选) 提交侧边栏修改**

```bash
git add qml/components/Sidebar.qml
git commit -m "feat: update sidebar entry from '月度目标' to '专注历史'

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 12: 最终完整性检查**

验证所有功能：

```bash
# 检查所有新增的Service文件
ls -la src/services/FocusHistoryService.*

# 检查CMakeLists.txt包含新文件
grep FocusHistoryService CMakeLists.txt

# 检查main.cpp注册了Service
grep focusHistoryService src/main.cpp

# 检查MonthGoalView使用了Service
grep focusHistoryService qml/views/MonthGoalView.qml
```

预期输出：所有文件和引用都存在

- [ ] **Step 13: 创建功能测试清单**

创建测试清单文档：

```bash
cat > docs/superpowers/testing/focus-history-manual-test.md << 'EOF'
# 月度专注记录功能手动测试清单

## 日历显示
- [ ] 日历显示正确的月份和日期
- [ ] 有专注记录的日期显示总时长
- [ ] 日期数字和时长文字颜色正确
- [ ] 鼠标悬停时边框变色
- [ ] 选中日期高亮显示

## 时间轴显示
- [ ] 点击日期后时间轴正确显示
- [ ] 时间轴按时间升序排列
- [ ] 任务标题正确显示
- [ ] 时间段格式正确（HH:MM - HH:MM）
- [ ] 时长格式正确（分钟/小时）
- [ ] 时间轴线和圆点显示正确
- [ ] 无记录时显示空状态

## 交互功能
- [ ] 月份切换功能正常
- [ ] "本月"按钮返回当前月份
- [ ] 切换月份后数据正确刷新
- [ ] 日期选择正常工作
- [ ] 滚动功能正常（多条记录时）

## 样式验证
- [ ] 所有颜色符合温暖纸质主题
- [ ] 字体大小和粗细正确
- [ ] 间距和对齐正确
- [ ] 圆角和边框正确
- [ ] 动画效果流畅

## 边界情况
- [ ] 无专注记录的月份正常显示
- [ ] 跨月边界正确处理
- [ ] 任务已删除时显示"未知任务"
- [ ] 时长为0时显示"0分钟"
EOF
```

- [ ] **Step 14: 运行完整回归测试**

```bash
./build/TomatoTodo
```

按照测试清单逐项验证所有功能

- [ ] **Step 15: 最终提交**

```bash
git add docs/superpowers/testing/focus-history-manual-test.md
git commit -m "docs: add manual testing checklist for focus history feature

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Part 3 完成检查清单

功能开发完成，确认以下内容：

- [ ] 日历格子显示日期数字和总专注时长
- [ ] 日历样式符合设计要求（颜色、边框、悬停、选中状态）
- [ ] 时间轴容器和标题正确显示
- [ ] 空状态正确显示
- [ ] 时间轴条目卡片正确显示所有信息
- [ ] 时间轴线和圆点装饰正确显示
- [ ] 所有交互功能正常工作
- [ ] 所有动画效果流畅
- [ ] 侧边栏入口文案已更新（如果需要）
- [ ] 所有调试日志已移除
- [ ] 手动测试清单已创建
- [ ] 所有修改已提交到git
- [ ] 应用可以成功编译和运行
- [ ] 所有功能符合设计文档要求

---

## 全功能完成总结

**实现的9个阶段：**

1. ✅ 创建FocusHistoryService.h框架
2. ✅ 创建FocusHistoryService.cpp框架
3. ✅ 实现getMonthSessions()方法
4. ✅ 实现辅助方法（getDaySessions, getDayTotalDuration, formatDuration）
5. ✅ 注册服务到QML（CMakeLists.txt + main.cpp）
6. ✅ 重构MonthGoalView - 移除旧逻辑
7. ✅ 添加专注记录数据绑定
8. ✅ 改造日历显示逻辑
9. ✅ 实现时间轴组件

**新建文件：**
- src/services/FocusHistoryService.h
- src/services/FocusHistoryService.cpp
- docs/superpowers/testing/focus-history-manual-test.md

**修改文件：**
- CMakeLists.txt
- src/main.cpp
- qml/views/MonthGoalView.qml
- qml/components/Sidebar.qml（可选）

**技术亮点：**
- Service + View分离架构
- LEFT JOIN处理已删除任务
- 前端数据聚合优化性能
- 温暖纸质主题配色
- 流畅的交互动画

**下一步建议：**
- 根据实际使用反馈优化UI细节
- 考虑添加周视图/年视图切换
- 考虑添加专注记录的统计图表
- 考虑添加导出月度报告功能
