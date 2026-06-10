# 月度专注记录功能实施计划 - Part 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建FocusHistoryService服务层，实现月度专注记录的数据查询功能

**Architecture:** 新建独立的FocusHistoryService单例服务，通过LEFT JOIN查询focus_sessions和tasks表，为QML层提供月度/日度专注记录数据和时长格式化工具方法

**Tech Stack:** C++17, Qt 6.8, SQLite, QObject/Q_INVOKABLE

---

## Task 1: 创建FocusHistoryService.h框架

**Files:**
- Create: `src/services/FocusHistoryService.h`

- [ ] **Step 1: 创建头文件框架 - 只包含基本结构和导入**

```cpp
#ifndef FOCUSHISTORYSERVICE_H
#define FOCUSHISTORYSERVICE_H

#include <QObject>
#include <QVariantList>
#include <QDate>
#include <QString>

class FocusHistoryService : public QObject
{
    Q_OBJECT

public:
    static FocusHistoryService* instance();

    // 方法声明稍后添加

private:
    explicit FocusHistoryService(QObject* parent = nullptr);
    static FocusHistoryService* m_instance;

    // 辅助方法声明稍后添加
};

#endif // FOCUSHISTORYSERVICE_H
```

- [ ] **Step 2: 验证文件创建**

```bash
cat src/services/FocusHistoryService.h
```

预期输出：显示刚创建的文件内容，包含基本的类框架

- [ ] **Step 3: 添加公共接口方法声明 - 第一个功能模块**

在 `// 方法声明稍后添加` 位置替换为：

```cpp
    // 获取指定月份的所有专注记录
    // 返回格式：[{id, taskId, taskTitle, startTime, endTime, durationSeconds, date}, ...]
    Q_INVOKABLE QVariantList getMonthSessions(int year, int month) const;
    
    // 获取指定日期的所有专注记录（按时间升序）
    Q_INVOKABLE QVariantList getDaySessions(const QDate& date) const;
```

- [ ] **Step 4: 添加辅助方法声明 - 第二个功能模块**

在 `// 辅助方法声明稍后添加` 位置替换为：

```cpp
    // 辅助方法
    QVariantList querySessions(const QString& whereClause, const QVariantList& bindValues = QVariantList()) const;
```

- [ ] **Step 5: 添加工具方法声明 - 第三个功能模块**

在 `getDaySessions` 方法声明后添加：

```cpp
    
    // 获取指定日期的总专注时长（秒数）
    Q_INVOKABLE int getDayTotalDuration(const QDate& date) const;
    
    // 工具方法：格式化时长（43分钟 / 1小时57分）
    Q_INVOKABLE QString formatDuration(int seconds) const;
```

- [ ] **Step 6: 验证完整头文件**

```bash
cat src/services/FocusHistoryService.h
```

预期输出：完整的头文件，包含所有方法声明

- [ ] **Step 7: 提交框架代码**

```bash
git add src/services/FocusHistoryService.h
git commit -m "feat: add FocusHistoryService header file framework

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: 创建FocusHistoryService.cpp框架

**Files:**
- Create: `src/services/FocusHistoryService.cpp`

- [ ] **Step 1: 创建实现文件框架 - 只包含导入和单例实现**

```cpp
#include "FocusHistoryService.h"
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QVariantMap>
#include <QDebug>

FocusHistoryService* FocusHistoryService::m_instance = nullptr;

FocusHistoryService* FocusHistoryService::instance()
{
    if (!m_instance) {
        m_instance = new FocusHistoryService();
    }
    return m_instance;
}

FocusHistoryService::FocusHistoryService(QObject* parent)
    : QObject(parent)
{
}

// 方法实现稍后添加
```

- [ ] **Step 2: 验证文件创建**

```bash
cat src/services/FocusHistoryService.cpp
```

预期输出：显示基础框架代码

- [ ] **Step 3: 添加querySessions辅助方法实现 - 第一个功能模块**

在 `// 方法实现稍后添加` 位置替换为：

```cpp
QVariantList FocusHistoryService::querySessions(const QString& whereClause, const QVariantList& bindValues) const
{
    QVariantList result;
    
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Database is not open";
        return result;
    }
    
    QString sql = R"(
        SELECT 
            fs.id,
            fs.task_id,
            COALESCE(t.title, '未知任务') AS task_title,
            fs.start_time,
            fs.end_time,
            fs.duration,
            DATE(fs.start_time) AS date
        FROM focus_sessions fs
        LEFT JOIN tasks t ON fs.task_id = t.id
    )";
    
    if (!whereClause.isEmpty()) {
        sql += " WHERE " + whereClause;
    }
    
    sql += " ORDER BY fs.start_time ASC";
    
    QSqlQuery query(db);
    query.prepare(sql);
    
    for (int i = 0; i < bindValues.size(); ++i) {
        query.bindValue(i, bindValues[i]);
    }
    
    if (!query.exec()) {
        qWarning() << "Query failed:" << query.lastError().text();
        return result;
    }
    
    while (query.next()) {
        QVariantMap session;
        session["id"] = query.value("id").toInt();
        session["taskId"] = query.value("task_id").toInt();
        session["taskTitle"] = query.value("task_title").toString();
        session["startTime"] = query.value("start_time").toString();
        session["endTime"] = query.value("end_time").toString();
        session["durationSeconds"] = query.value("duration").toInt();
        session["date"] = query.value("date").toString();
        result.append(session);
    }
    
    return result;
}
```

- [ ] **Step 4: 验证代码编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功（可能有链接错误，因为还未添加到CMakeLists.txt）

- [ ] **Step 5: 提交querySessions实现**

```bash
git add src/services/FocusHistoryService.cpp
git commit -m "feat: implement querySessions helper method

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: 实现getMonthSessions方法

**Files:**
- Modify: `src/services/FocusHistoryService.cpp`

- [ ] **Step 1: 添加getMonthSessions方法实现**

在 `querySessions` 方法后添加：

```cpp

QVariantList FocusHistoryService::getMonthSessions(int year, int month) const
{
    // 验证输入
    if (year < 2000 || year > 2100) {
        qWarning() << "Invalid year:" << year;
        return QVariantList();
    }
    
    if (month < 1 || month > 12) {
        qWarning() << "Invalid month:" << month;
        return QVariantList();
    }
    
    // 构造月份范围的WHERE子句
    QString startDate = QString("%1-%2-01").arg(year).arg(month, 2, 10, QChar('0'));
    
    // 计算下个月的第一天作为结束日期
    int nextYear = year;
    int nextMonth = month + 1;
    if (nextMonth > 12) {
        nextMonth = 1;
        nextYear++;
    }
    QString endDate = QString("%1-%2-01").arg(nextYear).arg(nextMonth, 2, 10, QChar('0'));
    
    QString whereClause = "DATE(fs.start_time) >= ? AND DATE(fs.start_time) < ?";
    QVariantList bindValues;
    bindValues << startDate << endDate;
    
    return querySessions(whereClause, bindValues);
}
```

- [ ] **Step 2: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 3: 提交getMonthSessions实现**

```bash
git add src/services/FocusHistoryService.cpp
git commit -m "feat: implement getMonthSessions method

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: 实现辅助方法

**Files:**
- Modify: `src/services/FocusHistoryService.cpp`

- [ ] **Step 1: 实现getDaySessions方法**

在 `getMonthSessions` 方法后添加：

```cpp

QVariantList FocusHistoryService::getDaySessions(const QDate& date) const
{
    if (!date.isValid()) {
        qWarning() << "Invalid date";
        return QVariantList();
    }
    
    QString dateStr = date.toString("yyyy-MM-dd");
    QString whereClause = "DATE(fs.start_time) = ?";
    QVariantList bindValues;
    bindValues << dateStr;
    
    return querySessions(whereClause, bindValues);
}
```

- [ ] **Step 2: 实现getDayTotalDuration方法**

在 `getDaySessions` 方法后添加：

```cpp

int FocusHistoryService::getDayTotalDuration(const QDate& date) const
{
    QVariantList sessions = getDaySessions(date);
    int total = 0;
    
    for (const QVariant& var : sessions) {
        QVariantMap session = var.toMap();
        total += session["durationSeconds"].toInt();
    }
    
    return total;
}
```

- [ ] **Step 3: 实现formatDuration方法**

在 `getDayTotalDuration` 方法后添加：

```cpp

QString FocusHistoryService::formatDuration(int seconds) const
{
    if (seconds < 60) {
        return "0分钟";
    }
    
    int minutes = seconds / 60;
    
    if (minutes < 60) {
        return QString("%1分钟").arg(minutes);
    }
    
    int hours = minutes / 60;
    int remainMinutes = minutes % 60;
    
    if (remainMinutes == 0) {
        return QString("%1小时").arg(hours);
    }
    
    return QString("%1小时%2分").arg(hours).arg(remainMinutes);
}
```

- [ ] **Step 4: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 5: 测试formatDuration逻辑**

创建一个临时测试文件验证格式化逻辑：

```bash
cat > /tmp/test_duration.cpp << 'EOF'
#include <QString>
#include <iostream>

QString formatDuration(int seconds) {
    if (seconds < 60) return "0分钟";
    int minutes = seconds / 60;
    if (minutes < 60) return QString("%1分钟").arg(minutes);
    int hours = minutes / 60;
    int remainMinutes = minutes % 60;
    if (remainMinutes == 0) return QString("%1小时").arg(hours);
    return QString("%1小时%2分").arg(hours).arg(remainMinutes);
}

int main() {
    std::cout << formatDuration(43 * 60).toStdString() << std::endl;      // 43分钟
    std::cout << formatDuration(117 * 60).toStdString() << std::endl;     // 1小时57分
    std::cout << formatDuration(120 * 60).toStdString() << std::endl;     // 2小时
    std::cout << formatDuration(30).toStdString() << std::endl;           // 0分钟
    return 0;
}
EOF
```

预期输出概念验证（不实际编译这个测试文件）

- [ ] **Step 6: 提交所有辅助方法**

```bash
git add src/services/FocusHistoryService.cpp
git commit -m "feat: implement helper methods (getDaySessions, getDayTotalDuration, formatDuration)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 7: 最终检查 - 验证所有方法实现完整**

```bash
grep -n "Q_INVOKABLE" src/services/FocusHistoryService.h
grep -n "FocusHistoryService::" src/services/FocusHistoryService.cpp | grep -v "m_instance"
```

预期输出：头文件中的4个Q_INVOKABLE方法声明，cpp文件中的5个方法实现（包括querySessions）

---

## Part 1 完成检查清单

在继续Part 2之前，确认以下内容：

- [ ] `src/services/FocusHistoryService.h` 文件存在且包含所有方法声明
- [ ] `src/services/FocusHistoryService.cpp` 文件存在且实现了所有方法
- [ ] 代码可以成功编译（即使未链接到主程序）
- [ ] 所有代码已提交到git
- [ ] 所有方法签名与头文件一致
- [ ] SQL查询使用了LEFT JOIN来处理已删除的任务
- [ ] formatDuration逻辑符合设计要求（分钟/小时格式）

**下一步：** 继续 Part 2，将FocusHistoryService注册到QML并开始重构MonthGoalView
