# 统计页趋势对比功能实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在统计页卡片中添加同比/环比对比信息，显示与前一时间段的百分比变化

**Architecture:** Service层添加对比查询方法，返回格式化的对比文本；StatCard组件添加对比显示属性；StatisticsView查询并绑定对比数据

**Tech Stack:** C++17, Qt 6, QML, StatisticsService

---

## Task 1: Service层 - 添加buildComparisonResult辅助方法

**Files:**
- Modify: `src/services/StatisticsService.h`
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 在StatisticsService.h添加私有方法声明**

在private区域添加：

```cpp
private:
    // ... 现有私有方法 ...
    
    // 构建对比结果的辅助方法
    QVariantMap buildComparisonResult(int currentValue, int previousValue, const QString& label) const;
```

- [ ] **Step 2: 在StatisticsService.cpp实现buildComparisonResult方法 - 第一部分（基础结构）**

在文件末尾添加方法框架：

```cpp
QVariantMap StatisticsService::buildComparisonResult(
    int currentValue, 
    int previousValue, 
    const QString& label
) const
{
    QVariantMap result;
    result["currentValue"] = currentValue;
    result["previousValue"] = previousValue;
    result["hasData"] = true;
    
    // 实现将在后续步骤补充
    
    return result;
}
```

- [ ] **Step 3: 实现前一值为0的特殊处理**

在buildComparisonResult方法中，return语句之前添加：

```cpp
    // 处理前一值为0的情况
    if (previousValue == 0) {
        result["changePercent"] = 0;
        if (currentValue > 0) {
            result["displayText"] = "首次记录";
            result["trend"] = 1;
        } else {
            result["displayText"] = "→ 0%";
            result["trend"] = 0;
        }
        return result;
    }
```

- [ ] **Step 4: 实现百分比计算和趋势判定**

在特殊处理之后，return之前添加：

```cpp
    // 计算百分比变化
    double changeRatio = (double)(currentValue - previousValue) / previousValue;
    int changePercent = qRound(changeRatio * 100);
    
    result["changePercent"] = changePercent;
    
    // 判定趋势
    QString arrow;
    int trend;
    if (changePercent > 0) {
        arrow = "↗";
        trend = 1;
    } else if (changePercent < 0) {
        arrow = "↘";
        trend = -1;
    } else {
        arrow = "→";
        trend = 0;
    }
    
    result["trend"] = trend;
    result["displayText"] = QString("%1 %2%3% vs %4")
        .arg(arrow)
        .arg(changePercent > 0 ? "+" : "")
        .arg(changePercent)
        .arg(label);
```

- [ ] **Step 5: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功，无错误

- [ ] **Step 6: 提交buildComparisonResult方法**

```bash
git add src/services/StatisticsService.h src/services/StatisticsService.cpp
git commit -m "feat(statistics): add buildComparisonResult helper method

- Calculate percentage change between current and previous values
- Handle special case when previous value is 0
- Return formatted comparison text with trend indicator
- Support arrow symbols: ↗ (up), ↘ (down), → (flat)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 2: Service层 - 实现getDayComparison方法

**Files:**
- Modify: `src/services/StatisticsService.h`
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 在StatisticsService.h添加getDayComparison方法声明**

在public Q_INVOKABLE方法区域添加：

```cpp
    Q_INVOKABLE QVariantMap getDayComparison(const QDate& date) const;
```

- [ ] **Step 2: 在StatisticsService.cpp实现getDayComparison方法**

在buildComparisonResult方法之前添加：

```cpp
QVariantMap StatisticsService::getDayComparison(const QDate& date) const
{
    if (!date.isValid()) {
        QVariantMap empty;
        empty["hasData"] = false;
        return empty;
    }
    
    QDate previousDate = date.addDays(-1);
    
    int currentDuration = calculateTotalDuration(date);
    int previousDuration = calculateTotalDuration(previousDate);
    
    return buildComparisonResult(currentDuration, previousDuration, "昨天");
}
```

- [ ] **Step 3: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 4: 提交getDayComparison方法**

```bash
git add src/services/StatisticsService.h src/services/StatisticsService.cpp
git commit -m "feat(statistics): implement getDayComparison method

- Compare current day with previous day
- Use calculateTotalDuration for focus duration
- Return comparison result via buildComparisonResult

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 3: Service层 - 实现getWeekComparison方法

**Files:**
- Modify: `src/services/StatisticsService.h`
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 在StatisticsService.h添加getWeekComparison方法声明**

在getDayComparison声明之后添加：

```cpp
    Q_INVOKABLE QVariantMap getWeekComparison(const QDate& weekStart) const;
```

- [ ] **Step 2: 在StatisticsService.cpp实现getWeekComparison方法**

在getDayComparison方法之后添加：

```cpp
QVariantMap StatisticsService::getWeekComparison(const QDate& weekStart) const
{
    if (!weekStart.isValid() || weekStart.dayOfWeek() != Qt::Monday) {
        QVariantMap empty;
        empty["hasData"] = false;
        return empty;
    }
    
    // 前一周的周一
    QDate previousWeekStart = weekStart.addDays(-7);
    
    // 计算当前周的总时长（周一到周日）
    int currentDuration = 0;
    for (int i = 0; i < 7; i++) {
        currentDuration += calculateTotalDuration(weekStart.addDays(i));
    }
    
    // 计算前一周的总时长
    int previousDuration = 0;
    for (int i = 0; i < 7; i++) {
        previousDuration += calculateTotalDuration(previousWeekStart.addDays(i));
    }
    
    return buildComparisonResult(currentDuration, previousDuration, "上周");
}
```

- [ ] **Step 3: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 4: 提交getWeekComparison方法**

```bash
git add src/services/StatisticsService.h src/services/StatisticsService.cpp
git commit -m "feat(statistics): implement getWeekComparison method

- Compare current week with previous week
- weekStart must be Monday
- Calculate total duration for 7 days in each week
- Return comparison result with 'vs 上周' label

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 4: Service层 - 实现getMonthComparison方法

**Files:**
- Modify: `src/services/StatisticsService.h`
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 在StatisticsService.h添加getMonthComparison方法声明**

在getWeekComparison声明之后添加：

```cpp
    Q_INVOKABLE QVariantMap getMonthComparison(int year, int month) const;
```

- [ ] **Step 2: 在StatisticsService.cpp实现getMonthComparison方法**

在getWeekComparison方法之后添加：

```cpp
QVariantMap StatisticsService::getMonthComparison(int year, int month) const
{
    // 验证输入
    if (year < 2000 || year > 2100 || month < 1 || month > 12) {
        QVariantMap empty;
        empty["hasData"] = false;
        return empty;
    }
    
    // 计算前一个月
    int previousYear = year;
    int previousMonth = month - 1;
    if (previousMonth < 1) {
        previousMonth = 12;
        previousYear--;
    }
    
    // 获取当前月的统计数据
    QVariantMap currentStats = getMonthStats(year, month);
    int currentDuration = currentStats["totalDuration"].toInt();
    
    // 获取前一个月的统计数据
    QVariantMap previousStats = getMonthStats(previousYear, previousMonth);
    int previousDuration = previousStats["totalDuration"].toInt();
    
    return buildComparisonResult(currentDuration, previousDuration, "上月");
}
```

- [ ] **Step 3: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 4: 提交getMonthComparison方法**

```bash
git add src/services/StatisticsService.h src/services/StatisticsService.cpp
git commit -m "feat(statistics): implement getMonthComparison method

- Compare current month with previous month
- Handle year boundary (Jan -> Dec of previous year)
- Reuse getMonthStats for data retrieval
- Return comparison result with 'vs 上月' label

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 5: StatCard组件 - 添加对比显示属性

**Files:**
- Modify: `qml/components/StatCard.qml`

- [ ] **Step 1: 在StatCard.qml根元素添加对比相关属性**

在现有property声明区域添加：

```qml
Rectangle {
    id: root

    property string title: ""
    property string value: "0"
    property string unit: ""
    property string subtitle: ""
    property int animationDelay: 0
    
    // 新增：对比数据属性
    property string comparisonText: ""      // 对比显示文本，如 "↗ +15% vs 昨天"
    property int comparisonTrend: 0         // 趋势：1=上升, 0=持平, -1=下降
    property bool showComparison: false     // 是否显示对比信息
```

- [ ] **Step 2: 验证QML语法**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功，QML无语法错误

- [ ] **Step 3: 提交属性添加**

```bash
git add qml/components/StatCard.qml
git commit -m "feat(statcard): add comparison display properties

- Add comparisonText for formatted comparison string
- Add comparisonTrend for trend direction (1/0/-1)
- Add showComparison flag to toggle display
- Prepare for comparison UI integration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 6: StatCard组件 - 添加对比信息UI元素

**Files:**
- Modify: `qml/components/StatCard.qml`

- [ ] **Step 1: 在StatCard的ColumnLayout中添加对比信息Text元素**

找到StatCard的ColumnLayout（包含title、value、subtitle的布局），在最后一个Text元素（subtitle）之后添加：

```qml
        Text {
            Layout.fillWidth: true
            visible: root.showComparison && root.comparisonText.length > 0
            text: root.comparisonText
            font.pixelSize: 13
            color: {
                if (root.comparisonTrend > 0) return "#4caf50"      // 绿色（上升）
                if (root.comparisonTrend < 0) return "#f44336"      // 红色（下降）
                return "#8b7355"                                     // 灰色（持平）
            }
            elide: Text.ElideRight
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
- 统计页面卡片正常显示（对比信息暂时不显示，因为showComparison默认false）
- 无QML错误或警告

- [ ] **Step 3: 提交对比UI元素**

```bash
git add qml/components/StatCard.qml
git commit -m "feat(statcard): add comparison info UI element

- Add Text element for displaying comparison text
- Color based on trend: green (up), red (down), gray (flat)
- Visible only when showComparison is true
- Position below subtitle with proper spacing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 7: StatisticsView - 添加对比数据属性

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 在StatisticsView根元素添加对比数据属性**

找到property声明区域（todayStats、weekStats等属性附近），添加：

```qml
    property var todayStats: ({ totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0 })
    property string currentTimeRange: "today"
    // ... 现有属性 ...
    
    // 新增：对比数据属性
    property var todayComparison: ({})
    property var weekComparison: ({})
    property var monthComparison: ({})
```

- [ ] **Step 2: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 3: 提交对比数据属性**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat(statistics): add comparison data properties

- Add todayComparison for daily comparison data
- Add weekComparison for weekly comparison data
- Add monthComparison for monthly comparison data
- Prepare for Service integration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 8: StatisticsView - 在refresh中查询对比数据

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 在refresh函数的今日模式分支中查询对比数据**

找到refresh()函数中的 `if (currentTimeRange === "today")` 分支，在查询todayStats之后添加：

```qml
        if (currentTimeRange === "today") {
            // 查询selectedDate这一天的数据
            root.todayStats = statisticsService.getDayStats(selectedDate)
            
            // 新增：查询对比数据
            root.todayComparison = statisticsService.getDayComparison(selectedDate)
            
            // 柱状图：查询selectedDate所在周的数据
            var monday = root.mondayOf(selectedDate)
            root.weekStats = statisticsService.getWeekStats(monday)
```

- [ ] **Step 2: 在本周模式分支中查询对比数据**

找到 `else if (currentTimeRange === "week")` 分支，在查询weekStats之后添加：

```qml
        else if (currentTimeRange === "week") {
            // 查询selectedWeekStart这一周的数据
            root.weekStats = statisticsService.getWeekStats(selectedWeekStart)
            
            // 新增：查询对比数据
            root.weekComparison = statisticsService.getWeekComparison(selectedWeekStart)
            
            var weekEnd = new Date(selectedWeekStart)
            weekEnd.setDate(weekEnd.getDate() + 6)
```

- [ ] **Step 3: 在本月模式分支中查询对比数据**

找到 `else if (currentTimeRange === "month")` 分支，在查询monthStats之后添加：

```qml
        else if (currentTimeRange === "month") {
            // 查询selectedYear/selectedMonth这个月的数据
            root.monthStats = statisticsService.getMonthStats(selectedYear, selectedMonth)
            root.monthWeeklySummary = statisticsService.getMonthWeeklySummary(selectedYear, selectedMonth)
            
            // 新增：查询对比数据
            root.monthComparison = statisticsService.getMonthComparison(selectedYear, selectedMonth)
```

- [ ] **Step 4: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 5: 提交refresh函数改造**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat(statistics): query comparison data in refresh

- Call getDayComparison in today mode
- Call getWeekComparison in week mode
- Call getMonthComparison in month mode
- Store results in comparison properties

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 9: StatisticsView - 绑定对比数据到卡片

**Files:**
- Modify: `qml/views/StatisticsView.qml`

- [ ] **Step 1: 找到今日模式的第一个StatCard（今日专注）并绑定对比数据**

找到今日模式下显示"今日专注"的StatCard，添加对比属性绑定：

```qml
                StatCard {
                    title: "今日专注"
                    value: root.totalDurationValue(root.todayStats.totalDuration)
                    unit: root.totalDurationUnit(root.todayStats.totalDuration)
                    
                    // 新增：绑定对比数据
                    showComparison: true
                    comparisonText: root.todayComparison.displayText || ""
                    comparisonTrend: root.todayComparison.trend || 0
                }
```

- [ ] **Step 2: 找到今日模式的第二个StatCard（任务完成）并绑定对比数据**

找到今日模式下显示"任务完成"的StatCard，添加对比属性绑定：

```qml
                StatCard {
                    title: "任务完成"
                    value: root.todayStats.completedTasks + " / " + root.todayStats.totalTasks
                    
                    // 新增：绑定对比数据
                    showComparison: true
                    comparisonText: root.todayComparison.displayText || ""
                    comparisonTrend: root.todayComparison.trend || 0
                }
```

- [ ] **Step 3: 找到本周/本月模式的StatCard并绑定对比数据**

根据currentTimeRange条件，找到本周和本月模式的StatCard，添加类似的绑定：

对于本周模式：
```qml
showComparison: true
comparisonText: root.weekComparison.displayText || ""
comparisonTrend: root.weekComparison.trend || 0
```

对于本月模式：
```qml
showComparison: true
comparisonText: root.monthComparison.displayText || ""
comparisonTrend: root.monthComparison.trend || 0
```

- [ ] **Step 4: 验证编译和运行**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
./build/TomatoTodo
```

预期结果：
- 应用启动成功
- 打开统计页面
- 今日模式下，卡片底部显示"vs 昨天"的对比信息（如果有历史数据）
- 切换到本周/本月模式，对比信息相应变化
- 绿色箭头表示增长，红色箭头表示下降

- [ ] **Step 5: 提交对比数据绑定**

```bash
git add qml/views/StatisticsView.qml
git commit -m "feat(statistics): bind comparison data to StatCards

- Enable showComparison for all stat cards
- Bind comparisonText and comparisonTrend to comparison properties
- Support today, week, and month modes
- Display trend with color-coded arrows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 10: 完整功能测试和提交

**Files:**
- All modified files

- [ ] **Step 1: 运行完整功能测试 - 今日模式**

```bash
./build/TomatoTodo
```

手动测试今日模式：

1. 打开统计页面，默认"今日"模式
2. 检查"今日专注"卡片是否显示对比信息（如：↗ +15% vs 昨天）
3. 检查"任务完成"卡片是否显示对比信息
4. 如果今天是第一天使用，应显示"首次记录"或不显示对比
5. 颜色检查：增长=绿色，下降=红色，持平=灰色

- [ ] **Step 2: 测试本周模式**

手动测试：

1. 切换到"本周"模式
2. 检查卡片是否显示"vs 上周"对比
3. 点击左箭头查看上周数据，对比应变为"vs 上上周"
4. 点击右箭头返回本周

- [ ] **Step 3: 测试本月模式**

手动测试：

1. 切换到"本月"模式
2. 检查卡片是否显示"vs 上月"对比
3. 点击左箭头查看上月数据，对比应变为"vs 上上月"
4. 测试跨年边界（如果当前是1月，查看去年12月）

- [ ] **Step 4: 测试边界情况**

手动测试：

1. 前一天/周/月无数据时，对比信息是否隐藏或显示"首次记录"
2. 百分比显示是否正确（增长显示+号，下降不显示）
3. 文字是否在卡片内不溢出
4. 切换时间范围时，对比信息是否正确更新

- [ ] **Step 5: 最终代码检查**

```bash
# 检查所有修改的文件
git status

# 检查代码差异
git diff
```

确认：

- 所有修改符合设计文档
- 没有遗留的调试代码
- 没有多余的空行或格式问题

- [ ] **Step 6: 最终提交**

```bash
git add src/services/StatisticsService.h
git add src/services/StatisticsService.cpp
git add qml/components/StatCard.qml
git add qml/views/StatisticsView.qml

git commit -m "feat(statistics): complete trend comparison feature

Implemented comparison display in statistics page:
- Service layer: comparison query methods for day/week/month
- StatCard: comparison text and trend display with color
- StatisticsView: integration and data binding

Features:
- Show percentage change vs previous period
- Color-coded arrows: ↗ green (up), ↘ red (down), → gray (flat)
- Auto-adjust comparison baseline when navigating history
- Handle edge cases: no previous data, zero division

Tested:
- Today mode: vs yesterday
- Week mode: vs last week
- Month mode: vs last month
- Arrow navigation with comparison updates

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 完成检查清单

功能完成后，确认以下内容：

- [ ] Service层三个对比方法正常工作
- [ ] buildComparisonResult正确处理所有边界情况
- [ ] StatCard显示对比信息，颜色正确
- [ ] 今日/本周/本月三种模式对比都正常
- [ ] 箭头导航时对比基准正确调整
- [ ] 无数据时不显示对比或显示"首次记录"
- [ ] 应用可以正常编译和运行
- [ ] 所有代码已提交到git
- [ ] 功能符合设计文档要求
