# 数据统计页面箭头导航功能实施计划 - Part 2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在StatisticsView中添加箭头按钮UI和导航逻辑，实现历史数据浏览功能

**Architecture:** 添加选中时间状态属性，实现三段式箭头按钮布局，添加前后导航函数，改造refresh逻辑使用选中时间查询

**Tech Stack:** Qt Quick/QML, 属性绑定, 日期计算

---

## Task 5: 在StatisticsView中添加时间状态属性

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 添加选中时间属性 - 第一个模块**

在currentTimeRange属性后添加：

```qml
    // 选中的具体时间
    property date selectedDate: new Date()                          // 今日模式用
    property date selectedWeekStart: mondayOf(new Date())           // 本周模式用（周一）
    property int selectedYear: new Date().getFullYear()             // 本月模式用
    property int selectedMonth: new Date().getMonth() + 1           // 本月模式用
```

- [ ] **Step 2: 添加canGoForward计算属性 - 第二个模块**

在上述属性后添加：

```qml
    // 判断是否可以前进（右箭头是否可用）
    readonly property bool canGoForward: {
        if (currentTimeRange === "today") {
            var today = new Date()
            today.setHours(0, 0, 0, 0)
            var selected = new Date(selectedDate)
            selected.setHours(0, 0, 0, 0)
            return selected.getTime() < today.getTime()
        } else if (currentTimeRange === "week") {
            var currentMonday = mondayOf(new Date())
            return selectedWeekStart.getTime() < currentMonday.getTime()
        } else { // month
            var now = new Date()
            return selectedYear < now.getFullYear() || 
                   (selectedYear === now.getFullYear() && selectedMonth < now.getMonth() + 1)
        }
    }
```

- [ ] **Step 3: 添加formatWeekRange辅助函数 - 第三个模块**

在现有函数区域添加：

```qml
    function formatWeekRange(start, end) {
        var startStr = (start.getMonth() + 1) + "." + start.getDate()
        var endStr = (end.getMonth() + 1) + "." + end.getDate()
        return startStr + "-" + endStr
    }
```

- [ ] **Step 4: 添加timeRangeDisplayText计算属性 - 第四个模块**

在canGoForward属性后添加：

```qml
    readonly property string timeRangeDisplayText: {
        if (currentTimeRange === "today") {
            var today = new Date()
            today.setHours(0, 0, 0, 0)
            var selected = new Date(selectedDate)
            selected.setHours(0, 0, 0, 0)
            if (selected.getTime() === today.getTime()) {
                return "今天"
            }
            return (selectedDate.getMonth() + 1) + "月" + selectedDate.getDate() + "日"
        } 
        else if (currentTimeRange === "week") {
            var currentMonday = mondayOf(new Date())
            if (selectedWeekStart.getTime() === currentMonday.getTime()) {
                return "本周"
            }
            var weekEnd = new Date(selectedWeekStart)
            weekEnd.setDate(weekEnd.getDate() + 6)
            return formatWeekRange(selectedWeekStart, weekEnd)
        } 
        else { // month
            var now = new Date()
            if (selectedYear === now.getFullYear() && selectedMonth === now.getMonth() + 1) {
                return "本月"
            }
            return selectedYear + "年" + selectedMonth + "月"
        }
    }
```

- [ ] **Step 5: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功，QML没有语法错误

- [ ] **Step 6: 提交时间状态属性**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat: add time selection state to StatisticsView

- Add selectedDate/selectedWeekStart/selectedYear/selectedMonth properties
- Add canGoForward computed property for right arrow state
- Add timeRangeDisplayText for dynamic button text
- Add formatWeekRange helper function

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: 实现箭头导航函数

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 实现goToPreviousPeriod函数 - 第一个模块**

在refresh函数后添加：

```qml
    function goToPreviousPeriod() {
        if (currentTimeRange === "today") {
            // 前一天
            selectedDate.setDate(selectedDate.getDate() - 1)
            selectedDate = new Date(selectedDate)  // 触发属性更新
        } 
        else if (currentTimeRange === "week") {
            // 前一周（周一往前7天）
            selectedWeekStart.setDate(selectedWeekStart.getDate() - 7)
            selectedWeekStart = new Date(selectedWeekStart)
        } 
        else { // month
            // 前一个月
            selectedMonth--
            if (selectedMonth < 1) {
                selectedMonth = 12
                selectedYear--
            }
        }
        
        refresh()
    }
```

- [ ] **Step 2: 实现goToNextPeriod函数 - 第二个模块**

在goToPreviousPeriod函数后添加：

```qml
    function goToNextPeriod() {
        if (!canGoForward) {
            return
        }
        
        if (currentTimeRange === "today") {
            // 后一天
            selectedDate.setDate(selectedDate.getDate() + 1)
            selectedDate = new Date(selectedDate)
        } 
        else if (currentTimeRange === "week") {
            // 后一周（周一往后7天）
            selectedWeekStart.setDate(selectedWeekStart.getDate() + 7)
            selectedWeekStart = new Date(selectedWeekStart)
        } 
        else { // month
            // 后一个月
            selectedMonth++
            if (selectedMonth > 12) {
                selectedMonth = 1
                selectedYear++
            }
        }
        
        refresh()
    }
```

- [ ] **Step 3: 添加currentTimeRange变化监听 - 第三个模块**

在Component.onCompleted前添加：

```qml
    onCurrentTimeRangeChanged: {
        // 切换模式时重置为当前时间
        if (currentTimeRange === "today") {
            selectedDate = new Date()
        } else if (currentTimeRange === "week") {
            selectedWeekStart = mondayOf(new Date())
        } else { // month
            var now = new Date()
            selectedYear = now.getFullYear()
            selectedMonth = now.getMonth() + 1
        }
        refresh()
    }
```

- [ ] **Step 4: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 5: 提交导航函数**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat: implement arrow navigation functions

- Add goToPreviousPeriod() to navigate backward
- Add goToNextPeriod() to navigate forward
- Add onCurrentTimeRangeChanged to reset selected time
- Handle day/week/month navigation logic

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: 改造时间范围切换器UI为三段式布局

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 找到现有切换器位置**

```bash
grep -n "timeRangeSelectorButton\|📅" qml/views/StatisticsView.qml
```

定位到现有切换器的Rectangle

- [ ] **Step 2: 替换为三段式布局 - 第一个模块**

找到现有的时间范围切换器Rectangle，将其外层包裹改为RowLayout：

```qml
                RowLayout {
                    spacing: 8
                    
                    // 左箭头
                    Rectangle {
                        id: leftArrowButton
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        color: "#faf6ee"
                        border.width: 1
                        border.color: "#e8dfc8"
                        radius: 6
                        
                        Text {
                            anchors.centerIn: parent
                            text: "←"
                            font.pixelSize: 16
                            color: "#5d4e37"
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.goToPreviousPeriod()
                        }
                    }
                    
                    // 中间显示（稍后添加）
                    
                    // 右箭头（稍后添加）
                }
```

- [ ] **Step 3: 修改中间显示区域 - 第二个模块**

在leftArrowButton后添加中间显示：

```qml
                    // 中间显示
                    Rectangle {
                        id: timeRangeSelectorButton
                        Layout.preferredWidth: 140
                        Layout.preferredHeight: 36
                        color: "#faf6ee"
                        border.width: 1
                        border.color: "#e8dfc8"
                        radius: 6
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 8
                            
                            Text {
                                id: timeRangeSelectorText
                                text: root.timeRangeDisplayText
                                font.pixelSize: 14
                                font.weight: Font.Medium
                                color: "#5d4e37"
                                Layout.fillWidth: true
                            }
                            
                            Text {
                                text: "▼"
                                font.pixelSize: 12
                                color: "#8b7355"
                            }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: timeRangeMenu.open()
                        }
                    }
```

- [ ] **Step 4: 添加右箭头按钮 - 第三个模块**

在中间显示后添加：

```qml
                    // 右箭头
                    Rectangle {
                        id: rightArrowButton
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        color: root.canGoForward ? "#faf6ee" : "#e0e0e0"
                        border.width: 1
                        border.color: root.canGoForward ? "#e8dfc8" : "#bdbdbd"
                        radius: 6
                        opacity: root.canGoForward ? 1.0 : 0.5
                        
                        Text {
                            anchors.centerIn: parent
                            text: "→"
                            font.pixelSize: 16
                            color: root.canGoForward ? "#5d4e37" : "#999"
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: root.canGoForward ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                            enabled: root.canGoForward
                            onClicked: root.goToNextPeriod()
                        }
                    }
```

- [ ] **Step 5: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 6: 运行应用验证UI显示**

```bash
./build/TomatoTodo
```

手动测试：
- 打开数据统计页面
- 应该看到三段式布局：← [今天 ▼] →
- 右箭头应该是禁用状态（灰色）
- 点击左箭头，中间显示变为具体日期
- 右箭头变为可用状态

- [ ] **Step 7: 提交UI改造**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat: refactor time range selector to three-part layout

- Add left arrow button for backward navigation
- Modify center display to use timeRangeDisplayText
- Add right arrow button with disabled state
- Apply warm theme styling to all buttons
- Connect arrows to navigation functions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: 改造refresh函数使用选中时间查询

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 改造今日模式查询 - 第一个模块**

找到refresh函数中的今日模式分支，修改为：

```qml
            if (currentTimeRange === "today") {
                // 查询selectedDate这一天的数据
                root.todayStats = statisticsService.getDayStats(selectedDate)
                
                // 柱状图：查询selectedDate所在周的数据
                var monday = root.mondayOf(selectedDate)
                root.weekStats = statisticsService.getWeekStats(monday)
                
                // 饼图：查询selectedDate这一天的数据
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(selectedDate, "yyyy-MM-dd"),
                    Qt.formatDate(selectedDate, "yyyy-MM-dd")
                )
            }
```

- [ ] **Step 2: 改造本周模式查询 - 第二个模块**

找到本周模式分支，修改为：

```qml
            else if (currentTimeRange === "week") {
                // 查询selectedWeekStart这一周的数据
                root.weekStats = statisticsService.getWeekStats(selectedWeekStart)
                var weekEnd = new Date(selectedWeekStart)
                weekEnd.setDate(weekEnd.getDate() + 6)
                
                // 卡片数据：计算有效天数、专注次数、本周累计
                var effectiveDays = statisticsService.getEffectiveDays(selectedWeekStart, weekEnd)
                var sessionCount = statisticsService.getFocusSessionCount(selectedWeekStart, weekEnd)
                var totalDuration = root.weekTotalDuration()
                
                root.todayStats = {
                    effectiveDays: effectiveDays,
                    sessionCount: sessionCount,
                    totalDuration: totalDuration,
                    completedTasks: 0,
                    totalTasks: 0,
                    completionRate: 0
                }
                
                // 饼图：查询这一周的数据
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(selectedWeekStart, "yyyy-MM-dd"),
                    Qt.formatDate(weekEnd, "yyyy-MM-dd"))
            }
```

- [ ] **Step 3: 改造本月模式查询 - 第三个模块**

找到本月模式分支，修改为：

```qml
            else if (currentTimeRange === "month") {
                // 查询selectedYear/selectedMonth这个月的数据
                root.monthStats = statisticsService.getMonthStats(selectedYear, selectedMonth)
                root.monthWeeklySummary = statisticsService.getMonthWeeklySummary(selectedYear, selectedMonth)
                
                // 卡片数据：使用monthStats
                root.todayStats = {
                    effectiveDays: root.monthStats.effectiveDays,
                    sessionCount: root.monthStats.sessionCount,
                    totalDuration: root.monthStats.totalDuration,
                    completedTasks: root.monthStats.completedTasks,
                    totalTasks: root.monthStats.totalTasks,
                    completionRate: 0
                }
                
                // 饼图：查询这个月的数据
                var firstDay = new Date(selectedYear, selectedMonth - 1, 1)
                var lastDay = new Date(selectedYear, selectedMonth, 0)
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(firstDay, "yyyy-MM-dd"),
                    Qt.formatDate(lastDay, "yyyy-MM-dd"))
            }
```

- [ ] **Step 4: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 5: 运行完整功能测试**

```bash
./build/TomatoTodo
```

手动测试完整流程：
1. 打开数据统计页面，默认显示"今天"
2. 点击左箭头，显示昨天的数据
3. 验证卡片、柱状图、饼图都更新了
4. 点击右箭头，返回今天
5. 右箭头变为禁用状态
6. 切换到"本周"模式，显示"本周"
7. 点击左箭头，显示"6.2-6.8"等日期范围
8. 柱状图显示上周的数据
9. 切换到"本月"模式，测试月份导航
10. 跨月测试：1月往前是12月

- [ ] **Step 6: 提交refresh函数改造**

```bash
git add qml/views/StatisticsView.qml
git commit -m "refactor: use selected time in refresh function

- Use selectedDate for today mode queries
- Use selectedWeekStart for week mode queries
- Use selectedYear/selectedMonth for month mode queries
- Update all data queries to use parameterized Service methods

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 7: 最终完整性检查**

```bash
# 检查所有新增属性
grep -n "selectedDate\|selectedWeekStart\|selectedYear\|selectedMonth\|canGoForward\|timeRangeDisplayText" qml/views/StatisticsView.qml

# 检查导航函数
grep -n "goToPreviousPeriod\|goToNextPeriod" qml/views/StatisticsView.qml

# 检查箭头按钮
grep -n "leftArrowButton\|rightArrowButton" qml/views/StatisticsView.qml
```

预期输出：所有新增代码都存在

- [ ] **Step 8: 运行回归测试**

按照设计文档中的测试清单逐项验证：
- [ ] 今日模式：左箭头查看昨天，右箭头返回今天
- [ ] 今日模式：右箭头在今天时禁用
- [ ] 本周模式：左箭头查看上周，右箭头返回本周
- [ ] 本周模式：右箭头在本周时禁用
- [ ] 本月模式：左箭头查看上月，右箭头返回本月
- [ ] 本月模式：右箭头在本月时禁用
- [ ] 切换模式后时间重置为当前时间段
- [ ] 跨月/跨年边界正确处理

---

## Part 2 完成检查清单

箭头导航功能开发完成，确认以下内容：

- [ ] 时间选择状态属性已添加
- [ ] canGoForward计算属性正确判断右箭头状态
- [ ] timeRangeDisplayText动态显示正确文本
- [ ] goToPreviousPeriod和goToNextPeriod函数正确实现
- [ ] onCurrentTimeRangeChanged监听正确重置时间
- [ ] 三段式箭头布局UI已实现
- [ ] 左右箭头样式符合温暖主题
- [ ] 右箭头禁用状态正确显示
- [ ] refresh函数使用选中时间查询
- [ ] 所有三种模式（今日/本周/本月）导航正常
- [ ] 应用可以成功编译和运行
- [ ] 所有修改已提交到git
- [ ] 手动测试清单全部通过

---

## 全功能完成总结

**实现的功能：**

✅ **Part 1 - Service层参数化：**
- getDayStats(date) 查询任意日期
- getWeekStats(weekStart) 查询任意周
- getMonthStats(year, month) 查询任意月份
- getMonthWeeklySummary(year, month) 查询任意月份的周汇总

✅ **Part 2 - UI和导航逻辑：**
- 三段式箭头布局：← [显示 ▼] →
- 左右箭头导航功能
- 右箭头禁用状态
- 动态显示文本（今天/具体日期/本周/日期范围/本月/年月）
- 模式切换自动重置时间

**修改文件：**
- src/services/StatisticsService.h
- src/services/StatisticsService.cpp
- qml/views/StatisticsView.qml

**技术亮点：**
- Service方法参数化，支持查询任意历史时间
- QML属性绑定实现响应式UI
- 计算属性动态判断箭头状态
- 日期边界正确处理（跨月/跨年）
- 温暖纸质主题一致性

**用户价值：**
- 可以查看任意历史日期的数据
- 可以对比不同时间段的专注情况
- 直观的箭头导航，符合用户习惯
- 与现有下拉菜单完美兼容

**下一步建议：**
- 根据实际使用反馈优化交互细节
- 考虑添加键盘快捷键（左右方向键）
- 考虑添加"回到今天"快捷按钮
- 考虑添加数据对比功能（本周 vs 上周）
