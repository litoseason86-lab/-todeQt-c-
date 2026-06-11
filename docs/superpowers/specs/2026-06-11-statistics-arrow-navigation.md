# 数据统计页面箭头导航功能设计文档

## 1. 概述

### 1.1 功能描述
在数据统计页面的时间范围切换器中添加左右箭头按钮，允许用户浏览任意历史日期/周/月的数据。用户可以通过点击左箭头查看过去的数据，通过右箭头返回到更近的日期（但不能超过今天/本周/本月）。

### 1.2 用户场景
- 用户打开数据统计页面，默认显示"今天"的数据，切换器显示 `← [今天 ▼] →`
- 用户点击左箭头，切换器变为 `← [6月10日 ▼] →`，页面显示6月10日的数据
- 用户继续点击左箭头，可以无限回溯查看历史数据
- 用户点击右箭头，返回到更近的日期，右箭头在当前日期时禁用
- 用户切换到"本周"模式，切换器显示 `← [本周 ▼] →`，点击左箭头查看上周数据
- 用户切换到"本月"模式，切换器显示 `← [本月 ▼] →`，点击左箭头查看上月数据

### 1.3 设计原则
- **直观性**：箭头方向清晰表达"前后浏览"的意图
- **一致性**：三种模式（今日/本周/本月）的箭头行为保持一致
- **边界限制**：右箭头不能超过当前时间段
- **状态反馈**：右箭头在到达当前时间段时禁用显示

---

## 2. UI设计

### 2.1 布局结构

**三段式布局：**
```
[← 左箭头] [中间显示 ▼] [→ 右箭头]
```

**按钮规格：**
- 左箭头按钮：36px × 36px
- 中间显示区域：120-140px × 36px（根据文字长度动态调整）
- 右箭头按钮：36px × 36px
- 按钮间距：8px

**样式统一：**
- 背景色：`#faf6ee`
- 边框：1px `#e8dfc8`
- 圆角：6px
- 箭头颜色：`#5d4e37`
- 禁用状态：背景 `#e0e0e0`，边框 `#bdbdbd`，箭头 `#999`，opacity 0.5

### 2.2 中间显示区域文本格式

**今日模式：**
- 今天：`"今天"`
- 其他日期：`"6月10日"`、`"6月9日"`

**本周模式：**
- 本周：`"本周"`
- 其他周：`"6.2-6.8"`、`"5.26-6.1"`

**本月模式：**
- 本月：`"本月"`
- 其他月：`"2026年5月"`、`"2025年12月"`

### 2.3 右箭头禁用规则

**今日模式：**
- 当 `selectedDate >= 今天` 时，右箭头禁用

**本周模式：**
- 当 `selectedWeekStart >= 本周一` 时，右箭头禁用

**本月模式：**
- 当 `selectedYear == 当前年 && selectedMonth >= 当前月` 时，右箭头禁用

---

## 3. 数据模型设计

### 3.1 新增状态属性

在StatisticsView.qml中新增：

```qml
// 选中的具体时间
property date selectedDate: new Date()                          // 今日模式用
property date selectedWeekStart: mondayOf(new Date())           // 本周模式用（周一）
property int selectedYear: new Date().getFullYear()             // 本月模式用
property int selectedMonth: new Date().getMonth() + 1           // 本月模式用

// 判断是否可以前进（右箭头是否可用）
readonly property bool canGoForward: {
    if (currentTimeRange === "today") {
        var today = new Date()
        today.setHours(0, 0, 0, 0)
        var selected = new Date(selectedDate)
        selected.setHours(0, 0, 0, 0)
        return selected < today
    } else if (currentTimeRange === "week") {
        return selectedWeekStart < mondayOf(new Date())
    } else { // month
        var now = new Date()
        return selectedYear < now.getFullYear() || 
               (selectedYear === now.getFullYear() && selectedMonth < now.getMonth() + 1)
    }
}
```

### 3.2 显示文本计算

```qml
readonly property string timeRangeDisplayText: {
    if (currentTimeRange === "today") {
        var today = new Date()
        if (selectedDate.toDateString() === today.toDateString()) {
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

function formatWeekRange(start, end) {
    var startStr = (start.getMonth() + 1) + "." + start.getDate()
    var endStr = (end.getMonth() + 1) + "." + end.getDate()
    return startStr + "-" + endStr
}
```

---

## 4. 交互逻辑设计

### 4.1 左箭头点击逻辑

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

### 4.2 右箭头点击逻辑

```qml
function goToNextPeriod() {
    if (!canGoForward) return
    
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

### 4.3 切换时间范围模式时的重置逻辑

```qml
// 当currentTimeRange变化时，重置选中时间为当前时间
onCurrentTimeRangeChanged: {
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

---

## 5. Service层改造

### 5.1 StatisticsService方法签名修改

**当前方法（固定查询当前时间）：**
```cpp
Q_INVOKABLE QVariantMap getTodayStats() const;
Q_INVOKABLE QVariantList getWeekStats() const;
Q_INVOKABLE QVariantMap getMonthStats() const;
Q_INVOKABLE QVariantList getMonthWeeklySummary() const;
```

**改造后（支持指定时间）：**
```cpp
// 查询指定日期的统计数据
Q_INVOKABLE QVariantMap getDayStats(const QDate& date) const;

// 查询指定周的统计数据（从周一开始的7天）
Q_INVOKABLE QVariantList getWeekStats(const QDate& weekStart) const;

// 查询指定月份的统计数据
Q_INVOKABLE QVariantMap getMonthStats(int year, int month) const;

// 查询指定月份的周汇总
Q_INVOKABLE QVariantList getMonthWeeklySummary(int year, int month) const;

// 保留原有的无参数版本（内部调用带参数版本）
Q_INVOKABLE QVariantMap getTodayStats() const {
    return getDayStats(QDate::currentDate());
}
```

### 5.2 getDayStats实现

```cpp
QVariantMap StatisticsService::getDayStats(const QDate& date) const
{
    QVariantMap result;
    result["totalDuration"] = 0;
    result["completedTasks"] = 0;
    result["totalTasks"] = 0;
    result["completionRate"] = 0;
    result["sessionCount"] = 0;
    
    if (!date.isValid()) {
        qWarning() << "Invalid date";
        return result;
    }
    
    QString dateStr = date.toString("yyyy-MM-dd");
    
    // 查询专注时长
    result["totalDuration"] = calculateTotalDuration(date);
    
    // 查询专注次数
    result["sessionCount"] = getFocusSessionCount(date, date);
    
    // 查询任务统计
    result["completedTasks"] = countCompletedTasks(date);
    result["totalTasks"] = countTotalTasks(date);
    
    int total = result["totalTasks"].toInt();
    int completed = result["completedTasks"].toInt();
    result["completionRate"] = (total > 0) ? (double)completed / total : 0.0;
    
    return result;
}
```

### 5.3 getWeekStats改造

```cpp
QVariantList StatisticsService::getWeekStats(const QDate& weekStart) const
{
    QVariantList result;
    
    if (!weekStart.isValid() || weekStart.dayOfWeek() != Qt::Monday) {
        qWarning() << "Invalid week start date or not Monday:" << weekStart;
        return result;
    }
    
    // 生成7天的数据
    for (int i = 0; i < 7; i++) {
        QDate day = weekStart.addDays(i);
        QVariantMap dayData;
        dayData["date"] = day;
        dayData["duration"] = calculateTotalDuration(day);
        result.append(dayData);
    }
    
    return result;
}
```

### 5.4 getMonthStats和getMonthWeeklySummary改造

```cpp
QVariantMap StatisticsService::getMonthStats(int year, int month) const
{
    // 验证输入
    if (year < 2000 || year > 2100 || month < 1 || month > 12) {
        qWarning() << "Invalid year/month:" << year << month;
        return QVariantMap();
    }
    
    QDate firstDay(year, month, 1);
    QDate lastDay(year, month, firstDay.daysInMonth());
    
    // 查询逻辑与原getMonthStats相同，只是使用传入的year/month
    // ... (实现代码)
}

QVariantList StatisticsService::getMonthWeeklySummary(int year, int month) const
{
    // 验证输入
    if (year < 2000 || year > 2100 || month < 1 || month > 12) {
        qWarning() << "Invalid year/month:" << year << month;
        return QVariantList();
    }
    
    QDate firstDay(year, month, 1);
    QDate lastDay(year, month, firstDay.daysInMonth());
    
    // 周汇总逻辑与原getMonthWeeklySummary相同，只是使用传入的year/month
    // ... (实现代码)
}
```

---

## 6. QML refresh函数改造

### 6.1 今日模式

```qml
if (currentTimeRange === "today") {
    // 查询selectedDate这一天的数据
    root.todayStats = statisticsService.getDayStats(selectedDate)
    
    // 柱状图：查询selectedDate所在周的数据
    var monday = mondayOf(selectedDate)
    root.weekStats = statisticsService.getWeekStats(monday)
    
    // 饼图：查询selectedDate这一天的数据
    root.categoryStats = statisticsService.getCategoryStats(
        Qt.formatDate(selectedDate, "yyyy-MM-dd"),
        Qt.formatDate(selectedDate, "yyyy-MM-dd")
    )
}
```

### 6.2 本周模式

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
        totalDuration: totalDuration
    }
    
    // 饼图：查询这一周的数据
    root.categoryStats = statisticsService.getCategoryStats(
        Qt.formatDate(selectedWeekStart, "yyyy-MM-dd"),
        Qt.formatDate(weekEnd, "yyyy-MM-dd")
    )
}
```

### 6.3 本月模式

```qml
else if (currentTimeRange === "month") {
    // 查询selectedYear/selectedMonth这个月的数据
    root.monthStats = statisticsService.getMonthStats(selectedYear, selectedMonth)
    root.monthWeeklySummary = statisticsService.getMonthWeeklySummary(selectedYear, selectedMonth)
    
    // 卡片数据：使用monthStats
    root.todayStats = {
        effectiveDays: root.monthStats.effectiveDays,
        sessionCount: root.monthStats.sessionCount,
        totalDuration: root.monthStats.totalDuration
    }
    
    // 饼图：查询这个月的数据
    var firstDay = new Date(selectedYear, selectedMonth - 1, 1)
    var lastDay = new Date(selectedYear, selectedMonth, 0)
    root.categoryStats = statisticsService.getCategoryStats(
        Qt.formatDate(firstDay, "yyyy-MM-dd"),
        Qt.formatDate(lastDay, "yyyy-MM-dd")
    )
}
```

---

## 7. 错误处理与边界情况

### 7.1 日期边界
- **最早日期**：理论上可以无限回溯，但数据库中没有数据的日期会显示空状态
- **最晚日期**：不能超过今天/本周/本月

### 7.2 跨年边界
- **本周跨年**：如2025年12月29日（周一）到2026年1月4日（周日），显示为 `"12.29-1.4"`
- **本月跨年**：月份正常递减，12月往前是11月，1月往前是上一年的12月

### 7.3 用户快速点击
- 左右箭头点击后立即触发refresh，避免连续快速点击导致状态不一致
- 可以考虑添加防抖逻辑（100-200ms）

### 7.4 数据为空
- 查询历史日期如果没有数据，卡片显示0，图表显示空状态
- 不影响箭头导航功能

---

## 8. 测试策略

### 8.1 功能测试
- [ ] 今日模式：点击左箭头查看昨天，右箭头返回今天
- [ ] 今日模式：连续点击左箭头查看多天前的数据
- [ ] 今日模式：在今天时右箭头禁用
- [ ] 本周模式：点击左箭头查看上周，右箭头返回本周
- [ ] 本周模式：在本周时右箭头禁用
- [ ] 本月模式：点击左箭头查看上月，右箭头返回本月
- [ ] 本月模式：在本月时右箭头禁用
- [ ] 切换模式后时间重置为当前时间段

### 8.2 边界测试
- [ ] 跨月查看：1月1日往前查看12月31日
- [ ] 跨年查看：2026年1月往前查看2025年12月
- [ ] 本周跨年：查看跨年的周数据正确
- [ ] 右箭头禁用状态正确显示

### 8.3 显示测试
- [ ] 今天显示"今天"
- [ ] 昨天及更早显示具体日期
- [ ] 本周显示"本周"
- [ ] 历史周显示日期范围（点号分隔）
- [ ] 本月显示"本月"
- [ ] 历史月显示年月

---

## 9. 实施计划概要

本功能将分为4个主要阶段实施：

### 阶段1：Service层改造
- 重构StatisticsService方法支持参数化查询
- 实现getDayStats(date)
- 修改getWeekStats接受weekStart参数
- 修改getMonthStats和getMonthWeeklySummary接受year/month参数

### 阶段2：StatisticsView添加状态和逻辑
- 添加selectedDate、selectedWeekStart、selectedYear、selectedMonth属性
- 添加canGoForward计算属性
- 添加timeRangeDisplayText计算属性
- 实现goToPreviousPeriod和goToNextPeriod函数
- 添加currentTimeRange变化监听重置逻辑

### 阶段3：UI组件实现
- 修改时间范围切换器为三段式布局
- 添加左箭头按钮
- 添加右箭头按钮（支持禁用状态）
- 中间显示区域使用timeRangeDisplayText

### 阶段4：refresh函数改造
- 今日模式使用selectedDate查询
- 本周模式使用selectedWeekStart查询
- 本月模式使用selectedYear/selectedMonth查询

---

## 10. 文件清单

### 10.1 修改文件
- `src/services/StatisticsService.h` - 修改方法签名，添加参数
- `src/services/StatisticsService.cpp` - 实现参数化查询方法
- `qml/views/StatisticsView.qml` - 添加状态、箭头按钮、逻辑函数

### 10.2 无需新建文件
所有功能通过修改现有文件实现

---

## 11. 与原有功能的兼容性

本功能是在现有时间范围切换功能基础上的增强，完全兼容：
- 保留原有的下拉菜单（今日/本周/本月切换）
- 新增箭头导航功能，不影响下拉菜单
- 所有数据查询逻辑保持一致
- 卡片和图表的显示逻辑不变

---

## 12. 总结

本设计文档定义了数据统计页面箭头导航功能的完整实现方案，包括：
- **UI设计**：三段式布局，左右箭头+中间显示
- **状态管理**：selectedDate/selectedWeekStart/selectedYear/selectedMonth
- **Service改造**：方法参数化，支持查询任意时间段
- **交互逻辑**：箭头点击、边界限制、模式切换重置
- **显示格式**：当前时间段简洁标识，历史时间段具体日期

设计遵循简洁直观的原则，与温暖纸质主题保持一致。
