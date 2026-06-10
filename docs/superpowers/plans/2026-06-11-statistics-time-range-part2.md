# 数据统计页面时间范围切换功能实施计划 - Part 2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在StatisticsView中添加时间范围切换器UI，重构数据绑定逻辑，优化页面排版

**Architecture:** 在标题行添加QML Menu切换器，添加currentTimeRange状态，重构refresh()函数支持多模式数据查询，动态绑定卡片和图表数据

**Tech Stack:** Qt Quick/QML, Qt Quick Controls, 属性绑定

---

## Task 4: 在StatisticsView中添加时间范围状态

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 添加时间范围相关属性 - 第一个模块**

在StatisticsView.qml顶部的property区域（todayStats之后）添加：

```qml
    property string currentTimeRange: "today"  // 时间范围: "today", "week", "month"
    property var monthStats: ({ totalDuration: 0, effectiveDays: 0, sessionCount: 0, completedTasks: 0, totalTasks: 0 })
    property var monthWeeklySummary: []
```

- [ ] **Step 2: 备份当前refresh函数**

```bash
grep -A 20 "function refresh()" qml/views/StatisticsView.qml > /tmp/original_refresh.txt
cat /tmp/original_refresh.txt
```

保存当前的refresh实现以供参考

- [ ] **Step 3: 重构refresh函数 - 添加今日模式逻辑**

找到现有的 `function refresh()` 函数，将其内容替换为：

```qml
    function refresh() {
        try {
            root.loadError = ""
            
            if (currentTimeRange === "today") {
                // 今日模式
                root.todayStats = statisticsService.getTodayStats()
                root.weekStats = statisticsService.getWeekStats()  // 柱状图仍显示本周
                
                // 饼图：今日数据
                var today = new Date()
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(today, "yyyy-MM-dd"),
                    Qt.formatDate(today, "yyyy-MM-dd")
                )
            } else {
                // 本周和本月模式稍后添加
                root.todayStats = statisticsService.getTodayStats()
                root.weekStats = statisticsService.getWeekStats()
                var start = root.mondayOf(new Date())
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(start, "yyyy-MM-dd"),
                    Qt.formatDate(root.endOfWeek(start), "yyyy-MM-dd"))
            }
        } catch (error) {
            root.loadError = "统计数据加载失败"
            root.todayStats = { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 }
            root.weekStats = []
            root.categoryStats = { categories: [], totalDuration: 0 }
        }
    }
```

- [ ] **Step 4: 添加本周模式逻辑 - 第二个模块**

在refresh函数中，将 `else` 分支替换为：

```qml
            else if (currentTimeRange === "week") {
                // 本周模式
                root.weekStats = statisticsService.getWeekStats()
                var start = root.mondayOf(new Date())
                var end = root.endOfWeek(start)
                
                // 卡片数据：计算有效天数、专注次数、本周累计
                var effectiveDays = statisticsService.getEffectiveDays(start, end)
                var sessionCount = statisticsService.getFocusSessionCount(start, end)
                var totalDuration = root.weekTotalDuration()
                
                root.todayStats = {
                    effectiveDays: effectiveDays,
                    sessionCount: sessionCount,
                    totalDuration: totalDuration,
                    completedTasks: 0,
                    totalTasks: 0,
                    completionRate: 0
                }
                
                // 饼图：本周数据
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(start, "yyyy-MM-dd"),
                    Qt.formatDate(end, "yyyy-MM-dd"))
            } else {
                // 今日模式（默认）
                root.todayStats = statisticsService.getTodayStats()
                root.weekStats = statisticsService.getWeekStats()
                var today = new Date()
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(today, "yyyy-MM-dd"),
                    Qt.formatDate(today, "yyyy-MM-dd")
                )
            }
```

- [ ] **Step 5: 添加本月模式逻辑 - 第三个模块**

将最后的 `else` 分支替换为：

```qml
            else if (currentTimeRange === "month") {
                // 本月模式
                root.monthStats = statisticsService.getMonthStats()
                root.monthWeeklySummary = statisticsService.getMonthWeeklySummary()
                
                // 卡片数据：使用monthStats
                root.todayStats = {
                    effectiveDays: root.monthStats.effectiveDays,
                    sessionCount: root.monthStats.sessionCount,
                    totalDuration: root.monthStats.totalDuration,
                    completedTasks: root.monthStats.completedTasks,
                    totalTasks: root.monthStats.totalTasks,
                    completionRate: 0
                }
                
                // 柱状图使用周汇总数据（不再使用weekStats）
                // 稍后在Task 5中处理
                
                // 饼图：本月数据
                var firstDay = new Date(new Date().getFullYear(), new Date().getMonth(), 1)
                var lastDay = new Date(new Date().getFullYear(), new Date().getMonth() + 1, 0)
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(firstDay, "yyyy-MM-dd"),
                    Qt.formatDate(lastDay, "yyyy-MM-dd"))
            } else {
                // 默认今日模式
                root.todayStats = statisticsService.getTodayStats()
                root.weekStats = statisticsService.getWeekStats()
                var today = new Date()
                root.categoryStats = statisticsService.getCategoryStats(
                    Qt.formatDate(today, "yyyy-MM-dd"),
                    Qt.formatDate(today, "yyyy-MM-dd")
                )
            }
```

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功，QML没有语法错误

- [ ] **Step 7: 提交状态管理代码**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat: add time range state management to StatisticsView

- Add currentTimeRange property (today/week/month)
- Add monthStats and monthWeeklySummary properties
- Refactor refresh() function to support multiple time ranges
- Implement data queries for today/week/month modes
- Update category stats based on selected time range

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: 实现时间范围切换器UI

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 找到标题区域的位置**

```bash
grep -n "数据统计\|看清时间流向" qml/views/StatisticsView.qml
```

定位到标题文本的位置（大约在180-192行）

- [ ] **Step 2: 重构标题区域为RowLayout - 第一个模块**

找到标题的ColumnLayout（大约175-193行），将其替换为：

```qml
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                spacing: 16
                
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Text {
                        text: "数据统计"
                        font.pixelSize: 24
                        font.bold: true
                        color: "#5d4e37"
                    }

                    Text {
                        text: "看清时间流向，比靠感觉复盘可靠。"
                        font.pixelSize: 13
                        color: "#8b7355"
                    }
                }
                
                // 切换器稍后添加
            }
```

- [ ] **Step 3: 添加时间范围切换按钮 - 第二个模块**

在ColumnLayout后添加：

```qml
                Rectangle {
                    id: timeRangeSelectorButton
                    Layout.preferredWidth: 110
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
                            text: {
                                if (root.currentTimeRange === "today") return "📅 今日"
                                if (root.currentTimeRange === "week") return "📅 本周"
                                return "📅 本月"
                            }
                            font.pixelSize: 14
                            font.weight: Font.Medium
                            color: "#5d4e37"
                        }
                        
                        Item { Layout.fillWidth: true }
                        
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

- [ ] **Step 4: 添加QML Menu组件 - 第三个模块**

在RowLayout外部（与RowLayout同级），添加Menu定义：

```qml
            Menu {
                id: timeRangeMenu
                y: timeRangeSelectorButton.height + 4
                x: timeRangeSelectorButton.x
                
                background: Rectangle {
                    implicitWidth: 120
                    color: "#faf8f3"
                    border.width: 1
                    border.color: "#d4a574"
                    radius: 8
                    
                    layer.enabled: true
                    layer.effect: DropShadow {
                        horizontalOffset: 0
                        verticalOffset: 4
                        radius: 12
                        samples: 25
                        color: "#26594e37"
                    }
                }
                
                // MenuItem稍后添加
            }
```

- [ ] **Step 5: 添加Menu的import语句**

在文件顶部的import区域添加（如果还没有）：

```qml
import QtQuick.Effects
```

- [ ] **Step 6: 添加MenuItem - 第四个模块**

在Menu内部添加3个MenuItem：

```qml
                MenuItem {
                    height: 40
                    
                    background: Rectangle {
                        color: parent.hovered ? "#f0e6d2" : "transparent"
                        radius: 6
                    }
                    
                    contentItem: RowLayout {
                        spacing: 8
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        
                        Text {
                            text: "📅"
                            font.pixelSize: 14
                        }
                        
                        Text {
                            text: "今日"
                            font.pixelSize: 14
                            color: "#5d4e37"
                        }
                    }
                    
                    onTriggered: {
                        root.currentTimeRange = "today"
                        root.refresh()
                    }
                }
                
                MenuItem {
                    height: 40
                    
                    background: Rectangle {
                        color: parent.hovered ? "#f0e6d2" : "transparent"
                        radius: 6
                    }
                    
                    contentItem: RowLayout {
                        spacing: 8
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        
                        Text {
                            text: "📅"
                            font.pixelSize: 14
                        }
                        
                        Text {
                            text: "本周"
                            font.pixelSize: 14
                            color: "#5d4e37"
                        }
                    }
                    
                    onTriggered: {
                        root.currentTimeRange = "week"
                        root.refresh()
                    }
                }
                
                MenuItem {
                    height: 40
                    
                    background: Rectangle {
                        color: parent.hovered ? "#f0e6d2" : "transparent"
                        radius: 6
                    }
                    
                    contentItem: RowLayout {
                        spacing: 8
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        
                        Text {
                            text: "📅"
                            font.pixelSize: 14
                        }
                        
                        Text {
                            text: "本月"
                            font.pixelSize: 14
                            color: "#5d4e37"
                        }
                    }
                    
                    onTriggered: {
                        root.currentTimeRange = "month"
                        root.refresh()
                    }
                }
```

- [ ] **Step 7: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 8: 运行应用验证UI显示**

```bash
./build/TomatoTodo
```

手动测试：
- 打开数据统计页面
- 标题行右侧应显示"📅 今日"按钮
- 点击按钮应弹出下拉菜单
- 菜单应显示3个选项

- [ ] **Step 9: 提交切换器UI代码**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat: add time range selector UI component

- Refactor title area to RowLayout with selector on right
- Add time range selector button with dynamic text
- Implement QML Menu with 3 MenuItems (today/week/month)
- Apply warm theme styling to menu and items
- Connect menu items to currentTimeRange and refresh()

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: 重构卡片和图表数据绑定

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 修改第一个StatCard（任务完成/有效天数） - 第一个模块**

找到第一个StatCard（todayFocusCard，大约220-227行），将其替换为：

```qml
                StatCard {
                    id: todayFocusCard
                    Layout.fillWidth: true
                    animationDelay: 0
                    title: {
                        if (root.currentTimeRange === "today") return "任务完成"
                        if (root.currentTimeRange === "week") return "有效天数"
                        return "有效天数"  // month
                    }
                    value: {
                        if (root.currentTimeRange === "today") {
                            return Number(root.todayStats.completedTasks || 0) + " / " + Number(root.todayStats.totalTasks || 0)
                        } else {
                            return Number(root.todayStats.effectiveDays || 0) + "天"
                        }
                    }
                    subtitle: {
                        if (root.currentTimeRange === "today") {
                            return "完成率 " + Math.round(Number(root.todayStats.completionRate || 0) * 100) + "%"
                        }
                        if (root.currentTimeRange === "week") return "本周有记录天数"
                        return "本月有记录天数"  // month
                    }
                }
```

- [ ] **Step 2: 修改第二个StatCard（专注次数） - 第二个模块**

找到第二个StatCard（taskCompletionCard），将其替换为：

```qml
                StatCard {
                    id: taskCompletionCard
                    Layout.fillWidth: true
                    animationDelay: 70
                    title: "专注次数"
                    value: {
                        if (root.currentTimeRange === "today") {
                            return Number(root.todayStats.sessionCount || 0) + "次"
                        } else {
                            return Number(root.todayStats.sessionCount || 0) + "次"
                        }
                    }
                    subtitle: {
                        if (root.currentTimeRange === "today") return "今日完成次数"
                        if (root.currentTimeRange === "week") return "本周完成次数"
                        return "本月完成次数"  // month
                    }
                }
```

- [ ] **Step 3: 修改第三个StatCard（今日专注/本周累计/本月累计） - 第三个模块**

找到第三个StatCard（weekTotalCard），将其替换为：

```qml
                StatCard {
                    id: weekTotalCard
                    Layout.fillWidth: true
                    animationDelay: 140
                    title: {
                        if (root.currentTimeRange === "today") return "今日专注"
                        if (root.currentTimeRange === "week") return "本周累计"
                        return "本月累计"  // month
                    }
                    value: root.totalDurationValue(root.todayStats.totalDuration || 0)
                    unit: root.totalDurationUnit(root.todayStats.totalDuration || 0)
                    subtitle: {
                        if (root.currentTimeRange === "today") return "当前自然日"
                        if (root.currentTimeRange === "week") return "本周专注时长"
                        return "本月专注时长"  // month
                    }
                }
```

- [ ] **Step 4: 添加monthBarData函数 - 第四个模块**

在barData()函数后添加新函数：

```qml
    function monthBarData() {
        var result = []
        for (var i = 0; i < root.monthWeeklySummary.length; i++) {
            var weekData = root.monthWeeklySummary[i]
            var duration = Number(weekData.duration || 0)
            result.push({
                label: weekData.label || ("第" + (i+1) + "周"),
                value: duration / 3600,  // 转换为小时
                displayValue: root.formatDuration(duration)
            })
        }
        return result
    }
```

- [ ] **Step 5: 修改ChartBar数据源和标题 - 第五个模块**

找到ChartBar组件（大约249-257行），修改其属性：

```qml
            ChartBar {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                title: root.currentTimeRange === "month" ? "本月专注趋势" : "本周专注趋势"
                dataPoints: root.currentTimeRange === "month" ? root.monthBarData() : root.barData()
                valueSuffix: "h"
                emptyText: root.currentTimeRange === "month" ? "本月还没有专注记录" : "本周还没有专注记录"
            }
```

- [ ] **Step 6: 修改ChartPie空状态文案 - 第六个模块**

找到ChartPie组件（大约259-267行），修改emptyText：

```qml
            ChartPie {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                Layout.bottomMargin: 24
                title: "科目时间分配"
                dataPoints: root.pieData()
                emptyText: {
                    if (root.currentTimeRange === "today") return "今日还没有可归类的专注记录"
                    if (root.currentTimeRange === "week") return "本周还没有可归类的专注记录"
                    return "本月还没有可归类的专注记录"
                }
            }
```

- [ ] **Step 7: 调整页面边距优化空间 - 第七个模块**

找到所有Layout.leftMargin和Layout.rightMargin为24的地方，将它们改为32：

```bash
sed -i '' 's/Layout.leftMargin: 24/Layout.leftMargin: 32/g' qml/views/StatisticsView.qml
sed -i '' 's/Layout.rightMargin: 24/Layout.rightMargin: 32/g' qml/views/StatisticsView.qml
```

找到RowLayout的spacing为12的地方，改为16：

```bash
grep -n "spacing: 12" qml/views/StatisticsView.qml
```

手动将StatCard所在的RowLayout的spacing从12改为16

- [ ] **Step 8: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 9: 运行完整功能测试**

```bash
./build/TomatoTodo
```

手动测试完整流程：
1. 打开数据统计页面，默认显示"今日"
2. 卡片显示：任务完成、专注次数、今日专注
3. 点击切换器选择"本周"
4. 卡片变为：有效天数、专注次数、本周累计
5. 柱状图显示本周7天
6. 点击切换器选择"本月"
7. 卡片变为：有效天数、专注次数、本月累计
8. 柱状图显示每周汇总
9. 饼图跟随时间范围切换
10. 页面排版合理，无过度留白

- [ ] **Step 10: 提交数据绑定和排版优化**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat: refactor data binding and optimize layout

- Dynamically bind StatCard titles and values based on time range
- Add monthBarData() function for weekly summary chart
- Update ChartBar to switch between daily and weekly data
- Update ChartPie empty text based on time range
- Increase left/right margins from 24px to 32px
- Increase card spacing from 12px to 16px
- Optimize space utilization to reduce right margin

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 11: 最终完整性检查**

```bash
# 检查currentTimeRange属性
grep -n "currentTimeRange" qml/views/StatisticsView.qml

# 检查所有StatCard的动态绑定
grep -A 10 "StatCard {" qml/views/StatisticsView.qml

# 检查Menu和MenuItem
grep -n "Menu\|MenuItem" qml/views/StatisticsView.qml
```

预期输出：所有组件都正确引用currentTimeRange

- [ ] **Step 12: 运行完整回归测试**

按照设计文档中的手动测试清单逐项验证：
- [ ] 时间范围切换器位置正确
- [ ] 点击切换器弹出下拉菜单
- [ ] 菜单样式符合温暖主题
- [ ] 今日模式卡片显示正确
- [ ] 本周模式卡片显示正确
- [ ] 本月模式卡片显示正确
- [ ] 柱状图正确切换数据
- [ ] 饼图正确切换数据
- [ ] 空状态文案正确
- [ ] 页面排版优化

---

## Part 2 完成检查清单

功能开发完成，确认以下内容：

- [ ] currentTimeRange属性已添加并默认为"today"
- [ ] refresh()函数支持3种时间范围模式
- [ ] 时间范围切换器UI已实现并正确显示
- [ ] Menu样式符合温暖纸质主题
- [ ] 3个StatCard动态绑定标题和数值
- [ ] ChartBar根据时间范围切换数据源
- [ ] ChartPie空状态文案动态更新
- [ ] 页面边距从24px增加到32px
- [ ] 卡片间距从12px增加到16px
- [ ] 应用可以成功编译和运行
- [ ] 所有修改已提交到git
- [ ] 手动测试清单全部通过

---

## 全功能完成总结

**实现的功能：**

✅ **Part 1 - Service层扩展：**
- StatisticsService新增4个公共方法
- 实现月度统计、有效天数、专注次数、周汇总查询
- 添加2个辅助方法处理日期计算

✅ **Part 2 - UI和数据绑定：**
- 添加时间范围切换器（标题行右侧）
- 实现QML Menu下拉菜单
- 3个StatCard动态显示不同时间范围数据
- 柱状图和饼图根据时间范围切换
- 优化页面排版避免右侧留白

**修改文件：**
- src/services/StatisticsService.h
- src/services/StatisticsService.cpp
- qml/views/StatisticsView.qml

**技术亮点：**
- Service层与UI层清晰分离
- QML属性绑定实现响应式UI
- SQL查询优化（DISTINCT DATE、duration过滤）
- 周汇总正确处理不完整周
- 温暖纸质主题一致性

**下一步建议：**
- 根据实际使用反馈调整UI细节
- 考虑添加数据缓存优化性能
- 考虑添加加载状态指示器
- 考虑添加数据导出功能
