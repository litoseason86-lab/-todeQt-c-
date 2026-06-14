# 数据统计页面箭头导航功能实施计划 - Part 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 改造StatisticsService支持参数化查询，允许查询任意历史日期/周/月的统计数据

**Architecture:** 修改现有Service方法签名，添加日期/时间参数，保留无参数版本作为便捷方法调用有参数版本

**Tech Stack:** C++17, Qt 6, SQLite, QDate

---

## Task 1: 改造StatisticsService.h方法签名

**Files:**
- Modify: `src/services/StatisticsService.h`

- [ ] **Step 1: 添加getDayStats方法声明 - 第一个模块**

在getTodayStats方法声明前添加：

```cpp
    // 查询指定日期的统计数据
    Q_INVOKABLE QVariantMap getDayStats(const QDate& date) const;
```

- [ ] **Step 2: 修改getWeekStats方法签名 - 第二个模块**

找到现有的 `getWeekStats()` 声明，修改为：

```cpp
    Q_INVOKABLE QVariantList getWeekStats(const QDate& weekStart) const;
```

- [ ] **Step 3: 修改getMonthStats方法签名 - 第三个模块**

找到 `getMonthStats()` 声明，修改为：

```cpp
    Q_INVOKABLE QVariantMap getMonthStats(int year, int month) const;
```

- [ ] **Step 4: 修改getMonthWeeklySummary方法签名 - 第四个模块**

找到 `getMonthWeeklySummary()` 声明，修改为：

```cpp
    Q_INVOKABLE QVariantList getMonthWeeklySummary(int year, int month) const;
```

- [ ] **Step 5: 验证头文件修改**

```bash
grep -n "getDayStats\|getWeekStats\|getMonthStats\|getMonthWeeklySummary" src/services/StatisticsService.h
```

预期输出：显示4个方法声明，都有参数

- [ ] **Step 6: 提交头文件修改**

```bash
git add src/services/StatisticsService.h
git commit -m "refactor: add parameters to StatisticsService methods

- Add getDayStats(date) for querying specific day
- Add weekStart parameter to getWeekStats()
- Add year/month parameters to getMonthStats()
- Add year/month parameters to getMonthWeeklySummary()

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: 实现getDayStats方法

**Files:**
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 添加getDayStats方法框架**

在getTodayStats方法之前添加：

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
        qWarning() << "Invalid date:" << date;
        return result;
    }
    
    // 实现稍后添加
    
    return result;
}
```

- [ ] **Step 2: 实现专注时长查询 - 第一个功能模块**

在方法中添加：

```cpp
    // 查询专注时长
    result["totalDuration"] = calculateTotalDuration(date);
```

- [ ] **Step 3: 实现专注次数查询 - 第二个功能模块**

添加：

```cpp
    // 查询专注次数
    result["sessionCount"] = getFocusSessionCount(date, date);
```

- [ ] **Step 4: 实现任务统计查询 - 第三个功能模块**

添加：

```cpp
    // 查询任务统计
    result["completedTasks"] = countCompletedTasks(date);
    result["totalTasks"] = countTotalTasks(date);
    
    int total = result["totalTasks"].toInt();
    int completed = result["completedTasks"].toInt();
    result["completionRate"] = (total > 0) ? (double)completed / total : 0.0;
```

- [ ] **Step 5: 修改getTodayStats使用getDayStats**

找到getTodayStats方法实现，替换为：

```cpp
QVariantMap StatisticsService::getTodayStats() const
{
    return getDayStats(QDate::currentDate());
}
```

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 7: 提交getDayStats实现**

```bash
git add src/services/StatisticsService.cpp
git commit -m "feat: implement getDayStats for querying specific day

- Query focus duration for specific date
- Query session count for specific date
- Query task statistics for specific date
- Refactor getTodayStats to use getDayStats

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: 改造getWeekStats方法

**Files:**
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 找到getWeekStats方法实现**

```bash
grep -n "QVariantList StatisticsService::getWeekStats" src/services/StatisticsService.cpp
```

定位到方法位置

- [ ] **Step 2: 修改方法签名添加参数**

将方法签名改为：

```cpp
QVariantList StatisticsService::getWeekStats(const QDate& weekStart) const
{
```

- [ ] **Step 3: 添加参数验证 - 第一个模块**

在方法开头添加：

```cpp
    QVariantList result;
    
    if (!weekStart.isValid()) {
        qWarning() << "Invalid weekStart date:" << weekStart;
        return result;
    }
    
    if (weekStart.dayOfWeek() != Qt::Monday) {
        qWarning() << "weekStart is not Monday:" << weekStart << "dayOfWeek:" << weekStart.dayOfWeek();
        return result;
    }
```

- [ ] **Step 4: 修改日期计算逻辑 - 第二个模块**

找到原来计算本周一的代码，删除它，直接使用传入的weekStart：

```cpp
    // 原代码删除：
    // QDate today = QDate::currentDate();
    // int dayOfWeek = today.dayOfWeek();
    // QDate monday = today.addDays(1 - dayOfWeek);
    
    // 使用传入的weekStart生成7天数据
    for (int i = 0; i < 7; i++) {
        QDate day = weekStart.addDays(i);
        QVariantMap dayData;
        dayData["date"] = day;
        dayData["duration"] = calculateTotalDuration(day);
        result.append(dayData);
    }
```

- [ ] **Step 5: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 6: 提交getWeekStats改造**

```bash
git add src/services/StatisticsService.cpp
git commit -m "refactor: add weekStart parameter to getWeekStats

- Accept weekStart parameter to query specific week
- Validate weekStart is valid and is Monday
- Generate 7 days data from weekStart
- Remove hardcoded current week calculation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: 改造getMonthStats和getMonthWeeklySummary方法

**Files:**
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 修改getMonthStats方法签名**

找到getMonthStats方法，修改签名为：

```cpp
QVariantMap StatisticsService::getMonthStats(int year, int month) const
{
```

- [ ] **Step 2: 添加参数验证 - 第一个模块**

在方法开头添加：

```cpp
    QVariantMap result;
    result["totalDuration"] = 0;
    result["effectiveDays"] = 0;
    result["sessionCount"] = 0;
    result["completedTasks"] = 0;
    result["totalTasks"] = 0;
    
    // 验证输入
    if (year < 2000 || year > 2100) {
        qWarning() << "Invalid year:" << year;
        return result;
    }
    
    if (month < 1 || month > 12) {
        qWarning() << "Invalid month:" << month;
        return result;
    }
```

- [ ] **Step 3: 修改日期范围计算 - 第二个模块**

找到原来计算本月日期的代码，替换为使用传入的year/month：

```cpp
    // 原代码删除：
    // QDate today = QDate::currentDate();
    // QDate firstDay(today.year(), today.month(), 1);
    // QDate lastDay(today.year(), today.month(), today.daysInMonth());
    
    // 使用传入的year/month
    QDate firstDay(year, month, 1);
    QDate lastDay(year, month, firstDay.daysInMonth());
```

其余查询逻辑保持不变

- [ ] **Step 4: 修改getMonthWeeklySummary方法签名**

找到getMonthWeeklySummary方法，修改签名为：

```cpp
QVariantList StatisticsService::getMonthWeeklySummary(int year, int month) const
{
```

- [ ] **Step 5: 添加参数验证和日期计算 - 第三个模块**

在方法开头添加：

```cpp
    QVariantList result;
    
    // 验证输入
    if (year < 2000 || year > 2100) {
        qWarning() << "Invalid year:" << year;
        return result;
    }
    
    if (month < 1 || month > 12) {
        qWarning() << "Invalid month:" << month;
        return result;
    }
    
    // 计算指定月份的第一天和最后一天
    QDate firstDay(year, month, 1);
    QDate lastDay(year, month, firstDay.daysInMonth());
```

然后删除原来计算本月日期的代码，其余逻辑保持不变

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 7: 提交getMonthStats和getMonthWeeklySummary改造**

```bash
git add src/services/StatisticsService.cpp
git commit -m "refactor: add year/month parameters to month statistics methods

- Add year/month parameters to getMonthStats()
- Add year/month parameters to getMonthWeeklySummary()
- Validate year range (2000-2100) and month range (1-12)
- Calculate firstDay/lastDay from parameters instead of current date

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 8: 最终检查 - 验证所有方法参数化完成**

```bash
grep -A 5 "StatisticsService::getDayStats\|StatisticsService::getWeekStats\|StatisticsService::getMonthStats\|StatisticsService::getMonthWeeklySummary" src/services/StatisticsService.cpp | head -30
```

预期输出：所有4个方法都有参数

---

## Part 1 完成检查清单

在继续Part 2之前，确认以下内容：

- [ ] StatisticsService.h 的4个方法声明都添加了参数
- [ ] getDayStats(date) 已实现并正确查询指定日期
- [ ] getTodayStats() 已重构为调用getDayStats
- [ ] getWeekStats(weekStart) 接受周一日期参数
- [ ] getMonthStats(year, month) 接受年月参数
- [ ] getMonthWeeklySummary(year, month) 接受年月参数
- [ ] 所有方法都有参数验证
- [ ] 代码可以成功编译
- [ ] 所有修改已提交到git

**下一步：** 继续 Part 2，在StatisticsView中添加箭头按钮UI和导航逻辑
