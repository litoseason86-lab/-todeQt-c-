# 数据统计页面时间范围切换功能实施计划 - Part 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 扩展StatisticsService，支持月度统计、有效天数、专注次数、周汇总查询

**Architecture:** 在现有StatisticsService中新增4个Q_INVOKABLE方法和2个私有辅助方法，通过SQL查询focus_sessions表获取月度数据

**Tech Stack:** C++17, Qt 6, SQLite, QObject/Q_INVOKABLE

---

## Task 1: 在StatisticsService.h中添加新方法声明

**Files:**
- Modify: `src/services/StatisticsService.h`

- [ ] **Step 1: 在public区域添加月度统计方法声明 - 第一个模块**

在现有的 `getCategoryStats` 方法声明后添加：

```cpp
    // 月度统计
    Q_INVOKABLE QVariantMap getMonthStats() const;
```

- [ ] **Step 2: 添加有效天数和专注次数方法声明 - 第二个模块**

在 `getMonthStats` 方法声明后添加：

```cpp
    Q_INVOKABLE int getEffectiveDays(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getFocusSessionCount(const QDate& startDate, const QDate& endDate) const;
```

- [ ] **Step 3: 添加周汇总方法声明 - 第三个模块**

在上述方法声明后添加：

```cpp
    Q_INVOKABLE QVariantList getMonthWeeklySummary() const;
```

- [ ] **Step 4: 在private区域添加辅助方法声明 - 第四个模块**

在现有私有方法后添加：

```cpp
    // 辅助方法
    QList<QDate> getUniqueFocusDates(const QDate& startDate, const QDate& endDate) const;
    QPair<QDate, QDate> getWeekRange(const QDate& mondayOfWeek) const;
```

- [ ] **Step 5: 验证头文件修改**

```bash
cat src/services/StatisticsService.h
```

预期输出：包含所有新方法声明

- [ ] **Step 6: 提交头文件修改**

```bash
git add src/services/StatisticsService.h
git commit -m "feat: add method declarations for time range statistics

- Add getMonthStats() for monthly statistics
- Add getEffectiveDays() to count days with focus sessions
- Add getFocusSessionCount() to count total sessions
- Add getMonthWeeklySummary() for weekly aggregation
- Add helper methods for date calculations

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: 实现getMonthStats方法

**Files:**
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 添加getMonthStats方法框架**

在StatisticsService.cpp的最后，getCategoryStats方法之后添加：

```cpp

QVariantMap StatisticsService::getMonthStats() const
{
    QVariantMap result;
    result["totalDuration"] = 0;
    result["effectiveDays"] = 0;
    result["sessionCount"] = 0;
    result["completedTasks"] = 0;
    result["totalTasks"] = 0;
    
    // 实现稍后添加
    
    return result;
}
```

- [ ] **Step 2: 实现本月时间范围计算 - 第一个功能模块**

在方法开头添加：

```cpp
QVariantMap StatisticsService::getMonthStats() const
{
    QVariantMap result;
    
    // 计算本月第一天和最后一天
    QDate today = QDate::currentDate();
    QDate firstDay(today.year(), today.month(), 1);
    QDate lastDay(today.year(), today.month(), today.daysInMonth());
    
    result["totalDuration"] = 0;
    result["effectiveDays"] = 0;
    result["sessionCount"] = 0;
    result["completedTasks"] = 0;
    result["totalTasks"] = 0;
    
    // 查询逻辑稍后添加
    
    return result;
}
```

- [ ] **Step 3: 实现总时长查询 - 第二个功能模块**

在初始化result后添加：

```cpp
    // 查询本月总专注时长
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Database is not open";
        return result;
    }
    
    QSqlQuery query(db);
    query.prepare(R"(
        SELECT SUM(duration) as total
        FROM focus_sessions
        WHERE DATE(start_time) >= :firstDay
          AND DATE(start_time) <= :lastDay
          AND duration >= 180
    )");
    query.bindValue(":firstDay", firstDay.toString("yyyy-MM-dd"));
    query.bindValue(":lastDay", lastDay.toString("yyyy-MM-dd"));
    
    if (query.exec() && query.next()) {
        result["totalDuration"] = query.value("total").toInt();
    }
```

- [ ] **Step 4: 实现有效天数和专注次数查询 - 第三个功能模块**

在总时长查询后添加：

```cpp
    // 查询有效天数和专注次数
    result["effectiveDays"] = getEffectiveDays(firstDay, lastDay);
    result["sessionCount"] = getFocusSessionCount(firstDay, lastDay);
```

- [ ] **Step 5: 实现任务统计查询 - 第四个功能模块**

在专注次数查询后添加：

```cpp
    // 查询本月任务统计
    query.prepare(R"(
        SELECT 
            COUNT(*) as total,
            SUM(CASE WHEN completed = 1 THEN 1 ELSE 0 END) as completed
        FROM tasks
        WHERE DATE(created_at) >= :firstDay
          AND DATE(created_at) <= :lastDay
    )");
    query.bindValue(":firstDay", firstDay.toString("yyyy-MM-dd"));
    query.bindValue(":lastDay", lastDay.toString("yyyy-MM-dd"));
    
    if (query.exec() && query.next()) {
        result["totalTasks"] = query.value("total").toInt();
        result["completedTasks"] = query.value("completed").toInt();
    }
```

- [ ] **Step 6: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 7: 提交getMonthStats实现**

```bash
git add src/services/StatisticsService.cpp
git commit -m "feat: implement getMonthStats method

- Calculate current month date range
- Query total focus duration (>= 3min)
- Call helper methods for effective days and session count
- Query task statistics for the month

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: 实现辅助方法

**Files:**
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: 实现getEffectiveDays方法框架**

在getMonthStats方法后添加：

```cpp

int StatisticsService::getEffectiveDays(const QDate& startDate, const QDate& endDate) const
{
    // 实现稍后添加
    return 0;
}
```

- [ ] **Step 2: 实现getEffectiveDays查询逻辑 - 第一个功能模块**

替换方法内容：

```cpp
int StatisticsService::getEffectiveDays(const QDate& startDate, const QDate& endDate) const
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Database is not open";
        return 0;
    }
    
    QSqlQuery query(db);
    query.prepare(R"(
        SELECT COUNT(DISTINCT DATE(start_time)) as days
        FROM focus_sessions
        WHERE DATE(start_time) >= :startDate
          AND DATE(start_time) <= :endDate
          AND duration >= 180
    )");
    query.bindValue(":startDate", startDate.toString("yyyy-MM-dd"));
    query.bindValue(":endDate", endDate.toString("yyyy-MM-dd"));
    
    if (query.exec() && query.next()) {
        return query.value("days").toInt();
    }
    
    return 0;
}
```

- [ ] **Step 3: 实现getFocusSessionCount方法 - 第二个功能模块**

在getEffectiveDays方法后添加：

```cpp

int StatisticsService::getFocusSessionCount(const QDate& startDate, const QDate& endDate) const
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Database is not open";
        return 0;
    }
    
    QSqlQuery query(db);
    query.prepare(R"(
        SELECT COUNT(*) as count
        FROM focus_sessions
        WHERE DATE(start_time) >= :startDate
          AND DATE(start_time) <= :endDate
          AND duration >= 180
          AND end_time IS NOT NULL
    )");
    query.bindValue(":startDate", startDate.toString("yyyy-MM-dd"));
    query.bindValue(":endDate", endDate.toString("yyyy-MM-dd"));
    
    if (query.exec() && query.next()) {
        return query.value("count").toInt();
    }
    
    return 0;
}
```

- [ ] **Step 4: 实现getMonthWeeklySummary方法框架 - 第三个功能模块**

在getFocusSessionCount方法后添加：

```cpp

QVariantList StatisticsService::getMonthWeeklySummary() const
{
    QVariantList result;
    
    // 计算本月第一天和最后一天
    QDate today = QDate::currentDate();
    QDate firstDay(today.year(), today.month(), 1);
    QDate lastDay(today.year(), today.month(), today.daysInMonth());
    
    // 实现稍后添加
    
    return result;
}
```

- [ ] **Step 5: 实现周汇总查询逻辑 - 第四个功能模块**

替换getMonthWeeklySummary方法内容：

```cpp
QVariantList StatisticsService::getMonthWeeklySummary() const
{
    QVariantList result;
    
    // 计算本月第一天和最后一天
    QDate today = QDate::currentDate();
    QDate firstDay(today.year(), today.month(), 1);
    QDate lastDay(today.year(), today.month(), today.daysInMonth());
    
    // 找到本月第一个周一
    QDate currentMonday = firstDay;
    while (currentMonday.dayOfWeek() != Qt::Monday && currentMonday <= lastDay) {
        currentMonday = currentMonday.addDays(1);
    }
    
    // 如果第一天不是周一，先处理第一周（不完整周）
    if (currentMonday > firstDay) {
        int duration = calculateTotalDuration(firstDay, currentMonday.addDays(-1));
        if (duration > 0 || firstDay.daysTo(currentMonday.addDays(-1)) >= 0) {
            QVariantMap week;
            week["label"] = "第1周";
            week["duration"] = duration;
            week["startDate"] = firstDay.toString("yyyy-MM-dd");
            week["endDate"] = currentMonday.addDays(-1).toString("yyyy-MM-dd");
            result.append(week);
        }
    }
    
    // 处理完整周
    int weekNumber = (currentMonday > firstDay) ? 2 : 1;
    while (currentMonday <= lastDay) {
        QDate weekEnd = currentMonday.addDays(6);
        if (weekEnd > lastDay) {
            weekEnd = lastDay;
        }
        
        int duration = calculateTotalDuration(currentMonday, weekEnd);
        
        QVariantMap week;
        week["label"] = QString("第%1周").arg(weekNumber);
        week["duration"] = duration;
        week["startDate"] = currentMonday.toString("yyyy-MM-dd");
        week["endDate"] = weekEnd.toString("yyyy-MM-dd");
        result.append(week);
        
        currentMonday = currentMonday.addDays(7);
        weekNumber++;
    }
    
    return result;
}
```

- [ ] **Step 6: 实现getUniqueFocusDates辅助方法 - 第五个功能模块**

在getMonthWeeklySummary方法后添加：

```cpp

QList<QDate> StatisticsService::getUniqueFocusDates(const QDate& startDate, const QDate& endDate) const
{
    QList<QDate> dates;
    
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Database is not open";
        return dates;
    }
    
    QSqlQuery query(db);
    query.prepare(R"(
        SELECT DISTINCT DATE(start_time) as date
        FROM focus_sessions
        WHERE DATE(start_time) >= :startDate
          AND DATE(start_time) <= :endDate
          AND duration >= 180
        ORDER BY date ASC
    )");
    query.bindValue(":startDate", startDate.toString("yyyy-MM-dd"));
    query.bindValue(":endDate", endDate.toString("yyyy-MM-dd"));
    
    if (query.exec()) {
        while (query.next()) {
            QDate date = QDate::fromString(query.value("date").toString(), "yyyy-MM-dd");
            if (date.isValid()) {
                dates.append(date);
            }
        }
    }
    
    return dates;
}
```

- [ ] **Step 7: 实现getWeekRange辅助方法 - 第六个功能模块**

在getUniqueFocusDates方法后添加：

```cpp

QPair<QDate, QDate> StatisticsService::getWeekRange(const QDate& mondayOfWeek) const
{
    QDate weekStart = mondayOfWeek;
    QDate weekEnd = mondayOfWeek.addDays(6);
    
    return qMakePair(weekStart, weekEnd);
}
```

- [ ] **Step 8: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 9: 运行应用验证Service可用**

```bash
./build/TomatoTodo
```

手动测试：打开应用，不应该有崩溃或编译错误

- [ ] **Step 10: 提交所有辅助方法**

```bash
git add src/services/StatisticsService.cpp
git commit -m "feat: implement helper methods for statistics

- Implement getEffectiveDays() with DISTINCT DATE query
- Implement getFocusSessionCount() counting completed sessions
- Implement getMonthWeeklySummary() with weekly aggregation logic
- Handle incomplete weeks at month boundaries
- Add getUniqueFocusDates() for date list retrieval
- Add getWeekRange() for week boundary calculation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 11: 最终检查 - 验证所有方法实现完整**

```bash
grep -n "Q_INVOKABLE" src/services/StatisticsService.h
grep -n "StatisticsService::" src/services/StatisticsService.cpp | grep -E "(getMonthStats|getEffectiveDays|getFocusSessionCount|getMonthWeeklySummary|getUniqueFocusDates|getWeekRange)"
```

预期输出：头文件中的4个Q_INVOKABLE方法声明，cpp文件中的6个方法实现

---

## Part 1 完成检查清单

在继续Part 2之前，确认以下内容：

- [ ] StatisticsService.h 包含所有新方法声明
- [ ] getMonthStats() 正确实现月度统计
- [ ] getEffectiveDays() 正确计算有效天数
- [ ] getFocusSessionCount() 正确统计专注次数
- [ ] getMonthWeeklySummary() 正确生成周汇总
- [ ] 所有辅助方法已实现
- [ ] 代码可以成功编译
- [ ] 所有修改已提交到git
- [ ] SQL查询使用duration >= 180过滤有效专注记录
- [ ] 周汇总正确处理不完整周

**下一步：** 继续 Part 2，在StatisticsView中添加时间范围切换器UI和数据绑定逻辑
