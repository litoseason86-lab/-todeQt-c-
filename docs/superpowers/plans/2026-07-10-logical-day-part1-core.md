# 逻辑日界点 · 计划一（核心 + 专注归日全口径 + 失效基建 + 设置 UI）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 引入可配置逻辑日界点（默认凌晨 4 点，0–6 整点）：AppSettings.dayStartHour、LogicalDay 纯函数库（C++/JS）、**所有 focus_sessions SQL 分桶入口**同口径改逻辑日、LogicalDayService 失效信号（构造即排期 + 跨日补例行）、StatisticsView 时间源改逻辑今天并订阅失效、设置弹窗步进器。

**Architecture:** 算法单一来源 `LogicalDay::dateOf(ts, h)`（纯函数，h 作参数不读单例）；SQL 层用 `date(start_time, '-N hours')` 修饰符统一归日（零 DB 迁移）；服务在调用点读 `AppSettings::instance()->dayStartHour()`；`LogicalDayService.changed()` 是"改设置/跨逻辑午夜"的统一失效信号，main.cpp 在 QML 加载前把它直连 `RoutineManager::materializeToday`（例行先落库、视图后刷新）。

**Tech Stack:** Qt 6.9 / C++17 / SQLite / QML / Qt Test / qmltestrunner

**Depends on:** 规格 `docs/superpowers/specs/2026-07-07-logical-day-boundary-design.md`（v9）。第一步创建分支 `logical-day`。

## Global Constraints

- 注释、提交说明中文，解释为什么/边界。
- 自动流程无头，禁 `open`。C++ 测试：`cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests <函数名>`；QML 单文件：`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`；全量：`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`。
- QML 测试**永不断言 `visible === true`**；断言驱动属性。tst_ui_optimization 与 tst_settings_dialog 的 `test_preferenceSwitchesAlignToGroupRightEdge` 有既有 offscreen 偶发，重跑一次区分。
- `dayStartHour` 归一化（非 clamp）：非 0–6 一律回 4；getter/setter 都归一。
- QML 取 hour 固定就地守卫写法（不封装 helper）：`(typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4`，配 `// qmllint disable unqualified`。
- 新/改 QML 文件 qmllint 不新增警告。

---

### Task 0: 创建分支

- [ ] **Step 1:**

```bash
git checkout -b logical-day
```

---

### Task 1: AppSettings.dayStartHour（含归一化）

**Files:**
- Modify: `src/services/AppSettings.h`
- Modify: `src/services/AppSettings.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces: `int AppSettings::dayStartHour() const`（默认 4，读取时归一化）、`void setDayStartHour(int)`（归一化 + 同值不发信号 + sync）、信号 `dayStartHourChanged()`。后续所有任务读它。

- [ ] **Step 1: 写失败测试**

`tests/ServiceTests.cpp`：private slots 里 `void appSettingsBackgroundThemeDefaultAndRoundTrip();`（约 379 行）之后加两个声明：

```cpp
    void appSettingsDayStartHourNormalizeAndPersist();
    void appSettingsDayStartHourRejectsCorruptIniValue();
```

实现加在 `appSettingsBackgroundThemeDefaultAndRoundTrip` 函数体之后：

```cpp
void ServiceTests::appSettingsDayStartHourNormalizeAndPersist()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    {
        AppSettings settings(path);
        QCOMPARE(settings.dayStartHour(), 4);

        QSignalSpy spy(&settings, &AppSettings::dayStartHourChanged);
        settings.setDayStartHour(5);
        QCOMPARE(settings.dayStartHour(), 5);
        QCOMPARE(spy.count(), 1);

        // 归一化不是 clamp：越界一律回默认 4（99 不该变成 6）。
        settings.setDayStartHour(99);
        QCOMPARE(settings.dayStartHour(), 4);
        settings.setDayStartHour(-1);
        QCOMPARE(settings.dayStartHour(), 4);

        // 同值不发信号。
        const int countBefore = spy.count();
        settings.setDayStartHour(4);
        QCOMPARE(spy.count(), countBefore);

        settings.setDayStartHour(6);
    }

    // 重新打开同一文件，验证持久化。
    AppSettings reloaded(path);
    QCOMPARE(reloaded.dayStartHour(), 6);
}

void ServiceTests::appSettingsDayStartHourRejectsCorruptIniValue()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("settings.ini"));

    // 坏值可能早已写进 ini（旧版本/手改），getter 必须在读取时归一，否则 99 漏进服务和 QML。
    {
        QSettings raw(path, QSettings::IniFormat);
        raw.setValue(QStringLiteral("logic/dayStartHour"), 99);
        raw.sync();
    }

    AppSettings settings(path);
    QCOMPARE(settings.dayStartHour(), 4);
}
```

- [ ] **Step 2: 跑测试确认编译失败（RED）**

Run: `cmake --build build 2>&1 | tail -5`
Expected: 编译错误 `no member named 'dayStartHour'`。

- [ ] **Step 3: 实现**

`src/services/AppSettings.h`：`backgroundTheme` 的 Q_PROPERTY 行后加：

```cpp
    Q_PROPERTY(int dayStartHour READ dayStartHour WRITE setDayStartHour NOTIFY dayStartHourChanged)
```

`setBackgroundTheme` 声明后加：

```cpp
    int dayStartHour() const;
    void setDayStartHour(int hour);
```

signals 里 `backgroundThemeChanged();` 后加：

```cpp
    void dayStartHourChanged();
```

private 里 `QSettings* m_settings` 前加：

```cpp
    static int normalizeDayStartHour(int hour);
```

`src/services/AppSettings.cpp`：匿名 namespace 里加键：

```cpp
const auto kDayStartHourKey = QStringLiteral("logic/dayStartHour");
```

文件末尾加：

```cpp
int AppSettings::normalizeDayStartHour(int hour)
{
    // 归一化而非 clamp：越界视为损坏配置，一律回默认 4（99 不该被"就近"成 6）。
    return (hour >= 0 && hour <= 6) ? hour : 4;
}

int AppSettings::dayStartHour() const
{
    // getter 也归一化：坏值可能早已持久化在 ini 里，必须在读取口拦住。
    return normalizeDayStartHour(m_settings->value(kDayStartHourKey, 4).toInt());
}

void AppSettings::setDayStartHour(int hour)
{
    const int normalized = normalizeDayStartHour(hour);
    if (dayStartHour() == normalized) {
        return;
    }

    m_settings->setValue(kDayStartHourKey, normalized);
    m_settings->sync();
    emit dayStartHourChanged();
}
```

- [ ] **Step 4: 跑测试（GREEN）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests appSettingsDayStartHourNormalizeAndPersist appSettingsDayStartHourRejectsCorruptIniValue`
Expected: 2 passed。

- [ ] **Step 5: 提交**

```bash
git add src/services/AppSettings.h src/services/AppSettings.cpp tests/ServiceTests.cpp
git commit -m "AppSettings 增加 dayStartHour（默认4，getter/setter 双向归一化）"
```

---

### Task 2: LogicalDay.h 纯函数库

**Files:**
- Create: `src/services/LogicalDay.h`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Produces: `LogicalDay::dateOf(const QDateTime&, int) -> QDate`（唯一算法）、`today(int) -> QDate`、`msUntilNextBoundary(const QDateTime&, int) -> qint64`、`sqlShift(int) -> QString`（`"-4 hours"`）。后续任务全部消费。

- [ ] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` 顶部 include 区（`#include "../src/services/AppSettings.h"` 后）加：

```cpp
#include "../src/services/LogicalDay.h"
```

private slots（Task 1 新增声明后）加：

```cpp
    void logicalDayDateOfBoundaries();
    void logicalDayMsUntilNextBoundary();
```

实现（Task 1 新增函数体后）：

```cpp
void ServiceTests::logicalDayDateOfBoundaries()
{
    const QDate day(2026, 7, 8);

    // h=4：3:59 归前一天、4:00 归当天——日界点的核心语义。
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(3, 59)), 4), day.addDays(-1));
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(4, 0)), 4), day);

    // h=0 等价物理午夜；h=6 上界。
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(0, 0)), 0), day);
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(5, 59)), 6), day.addDays(-1));
    QCOMPARE(LogicalDay::dateOf(QDateTime(day, QTime(6, 0)), 6), day);

    // 跨月、跨年。
    QCOMPARE(LogicalDay::dateOf(QDateTime(QDate(2026, 8, 1), QTime(1, 0)), 4), QDate(2026, 7, 31));
    QCOMPARE(LogicalDay::dateOf(QDateTime(QDate(2027, 1, 1), QTime(2, 30)), 4), QDate(2026, 12, 31));

    // today 是 dateOf(now) 的薄包装：只验证等价，不模拟真实凌晨。
    QCOMPARE(LogicalDay::today(4), LogicalDay::dateOf(QDateTime::currentDateTime(), 4));

    QCOMPARE(LogicalDay::sqlShift(4), QStringLiteral("-4 hours"));
    QCOMPARE(LogicalDay::sqlShift(0), QStringLiteral("-0 hours"));
}

void ServiceTests::logicalDayMsUntilNextBoundary()
{
    const QDate day(2026, 7, 8);

    // 界点前：2:00 → 4:00 差 2 小时。
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(2, 0)), 4), qint64(2) * 3600 * 1000);
    // 界点后：5:00 → 次日 4:00 差 23 小时。
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(5, 0)), 4), qint64(23) * 3600 * 1000);
    // 恰在界点：排到下一天（>0，定时器不会 0ms 空转）。
    QCOMPARE(LogicalDay::msUntilNextBoundary(QDateTime(day, QTime(4, 0)), 4), qint64(24) * 3600 * 1000);
}
```

- [ ] **Step 2: 确认编译失败（RED）**

Run: `cmake --build build 2>&1 | tail -5`
Expected: `'../src/services/LogicalDay.h' file not found`。

- [ ] **Step 3: 创建 `src/services/LogicalDay.h`**

```cpp
#ifndef LOGICALDAY_H
#define LOGICALDAY_H

#include <QDate>
#include <QDateTime>
#include <QString>
#include <QTime>

// 逻辑日：dayStartHour（0-6 整点）前的凌晨时间归前一天。
// 全部纯自由函数、dayStartHour 作参数——不读单例，保证可单测；
// 入参合法性（归一化）由 AppSettings 负责，这里假定已是 0-6。
namespace LogicalDay {

// 某时间戳的逻辑日。唯一算法所在，其余函数不得复制这段逻辑。
inline QDate dateOf(const QDateTime& ts, int dayStartHour)
{
    return ts.addSecs(-dayStartHour * 3600).date();
}

// 逻辑今天：dateOf 的薄包装。
inline QDate today(int dayStartHour)
{
    return dateOf(QDateTime::currentDateTime(), dayStartHour);
}

// 距下一逻辑日界点的毫秒数（供失效定时器排期）。恰在界点时排到下一天，避免 0ms 空转。
inline qint64 msUntilNextBoundary(const QDateTime& now, int dayStartHour)
{
    QDateTime boundary(now.date(), QTime(dayStartHour, 0));
    if (now >= boundary) {
        boundary = boundary.addDays(1);
    }
    return now.msecsTo(boundary);
}

// SQLite date() 修饰符：date(start_time, sqlShift(h)) 即按逻辑日取日期。
inline QString sqlShift(int dayStartHour)
{
    return QStringLiteral("-%1 hours").arg(dayStartHour);
}

}

#endif // LOGICALDAY_H
```

- [ ] **Step 4: 跑测试（GREEN）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests logicalDayDateOfBoundaries logicalDayMsUntilNextBoundary`
Expected: 2 passed。

- [ ] **Step 5: 提交**

```bash
git add src/services/LogicalDay.h tests/ServiceTests.cpp
git commit -m "新增 LogicalDay 纯函数库（逻辑日算法单一来源，与时钟解耦可单测）"
```

---

### Task 3: StatisticsService 分桶 + today 全改逻辑日

**Files:**
- Modify: `src/services/StatisticsService.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Consumes: Task 1 `dayStartHour()`、Task 2 `LogicalDay::sqlShift/today`。
- Produces: getDayStats/getFocusSessionCount/getUniqueFocusDates/getCategoryStats 按逻辑日分桶；getTodayStats/getWeekStats()/getMonthStats()/getMonthWeeklySummary() 的"今天"= 逻辑今天。

- [ ] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` 匿名 namespace 里 `insertFocusSessionRow` 后加带时刻的插入 helper：

```cpp
bool insertFocusSessionRowAt(int taskId, const QDate& date, const QString& startTime,
                             const QString& endTime, int duration)
{
    // 与 insertFocusSessionRow 的区别：起止时刻可指定，用于构造日界点边界 session。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration) "
        "VALUES (:taskId, :startTime, :endTime, :duration)"));
    query.bindValue(QStringLiteral(":taskId"), taskId > 0 ? QVariant(taskId) : QVariant());
    query.bindValue(QStringLiteral(":startTime"), dateTimeText(date, startTime));
    query.bindValue(QStringLiteral(":endTime"), dateTimeText(date, endTime));
    query.bindValue(QStringLiteral(":duration"), duration);

    if (!query.exec()) {
        qWarning() << "Failed to insert boundary focus session:" << query.lastError().text();
        return false;
    }

    return true;
}
```

同一匿名 namespace 再加"服务口径的今天"helper（后续既有用例改用它——服务切逻辑日后，凌晨 0-4 点跑测试时 `QDate::currentDate()` ≠ 服务的今天，会假失败；用户常在凌晨自习后跑构建，必须消除）：

```cpp
QDate logicalToday()
{
    // 与服务同口径的"今天"：测试跨 0-4 点运行时不与服务打架。
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}
```

private slots 加：

```cpp
    void statisticsBucketsSessionsByLogicalDay();
    void statisticsTodayUsesLogicalToday();
```

实现：

```cpp
void ServiceTests::statisticsBucketsSessionsByLogicalDay()
{
    // 分桶测试不依赖时钟：固定 h=4 + 固定时间戳 + 显式日期查询。
    AppSettings::instance()->setDayStartHour(4);
    StatisticsService* service = StatisticsService::instance();

    const QDate day(2026, 7, 8);
    const int taskId = insertTaskRow(QStringLiteral("凌晨自习"), day, QStringLiteral("数学"));
    QVERIFY(taskId > 0);

    // 01:00 在日界点前 → 归 7月7日；05:00 在其后 → 归 7月8日。
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("01:00:00"), QStringLiteral("01:25:00"), 1500));
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("05:00:00"), QStringLiteral("05:15:00"), 900));

    // 总时长（getDayStats → calculateTotalDuration/queryTotalDurationForRange）。
    QCOMPARE(service->getDayStats(day.addDays(-1)).value(QStringLiteral("totalDuration")).toInt(), 1500);
    QCOMPARE(service->getDayStats(day).value(QStringLiteral("totalDuration")).toInt(), 900);

    // 次数（getFocusSessionCount）。
    QCOMPARE(service->getFocusSessionCount(day.addDays(-1), day.addDays(-1)), 1);
    QCOMPARE(service->getFocusSessionCount(day, day), 1);

    // 有效天数（getUniqueFocusDates：SELECT 与 WHERE 三处必须同口径）。
    QCOMPARE(service->getEffectiveDays(day.addDays(-1), day), 2);
    QCOMPARE(service->getEffectiveDays(day.addDays(-1), day.addDays(-1)), 1);

    // 分类统计（getCategoryStats 的 WHERE 两处）。
    const QVariantMap categoryStats = service->getCategoryStats(
        day.addDays(-1).toString(Qt::ISODate), day.addDays(-1).toString(Qt::ISODate));
    QCOMPARE(categoryStats.value(QStringLiteral("totalDuration")).toInt(), 1500);
}

void ServiceTests::statisticsTodayUsesLogicalToday()
{
    AppSettings::instance()->setDayStartHour(4);
    StatisticsService* service = StatisticsService::instance();

    // 薄包装只验证等价于 LogicalDay::today(h) 的显式日期查询，不模拟真实凌晨。
    const QDate logicalToday = LogicalDay::today(4);
    const int taskId = insertTaskRow(QStringLiteral("今日等价"), logicalToday, QStringLiteral("英语"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, logicalToday, QStringLiteral("12:00:00"), QStringLiteral("12:30:00"), 1800));

    QCOMPARE(service->getTodayStats(), service->getDayStats(logicalToday));
}
```

`ServiceTests::cleanup()`（约 460 行）里 `FocusTimer::instance()->resetSession();` 后加一行（全局单例设置自愈，防用例间串扰）：

```cpp
    AppSettings::instance()->setDayStartHour(4);
```

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests statisticsBucketsSessionsByLogicalDay`
Expected: FAIL——01:00 的 session 仍按物理日归 7月8日（totalDuration 比对失败）。

- [ ] **Step 3: 实现**

`src/services/StatisticsService.cpp` 顶部 include 区加：

```cpp
#include "AppSettings.h"
#include "LogicalDay.h"
```

四处 SQL + 绑定（`:dayShift` 命名占位符同名可复用，绑一次即可）：

1）`queryTotalDurationForRange`（约 120-129 行）SQL 改为：

```cpp
    query.prepare(QStringLiteral(
        "SELECT COALESCE(SUM(duration), 0) FROM focus_sessions "
        "WHERE date(start_time, :dayShift) >= :startDate "
        "AND date(start_time, :dayShift) <= :endDate "
        "AND end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
```

（原有三个 bindValue 保留。）

2）`getCategoryStats`（约 336-337 行）两处 `date(f.start_time)` 改 `date(f.start_time, :dayShift)`，绑定区加同一行 `query.bindValue(QStringLiteral(":dayShift"), LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));`

3）`getFocusSessionCount`（约 484-485 行）两处 `date(start_time)` 改 `date(start_time, :dayShift)`，加同一 bindValue。

4）`getUniqueFocusDates`（约 615-618 行）**SELECT 与 WHERE 三处**都改：

```cpp
    query.prepare(QStringLiteral(
        "SELECT DISTINCT date(start_time, :dayShift) AS focus_date "
        "FROM focus_sessions "
        "WHERE date(start_time, :dayShift) >= :startDate "
        "AND date(start_time, :dayShift) <= :endDate "
        "AND end_time IS NOT NULL "
        "AND duration IS NOT NULL "
        "AND duration >= :minDuration "
        "ORDER BY focus_date ASC"));
    query.bindValue(QStringLiteral(":dayShift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
```

四处 today（把 `QDate::currentDate()` 换成逻辑今天）：

- `getTodayStats`（约 173 行）：`return getDayStats(LogicalDay::today(AppSettings::instance()->dayStartHour()));`
- `getWeekStats()`（约 244 行）：`const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());`
- `getMonthStats()`（约 424 行）：同上替换 `const QDate today = ...`
- `getMonthWeeklySummary()`（约 538 行）：同上。

- [ ] **Step 4: 既有"今天"耦合用例改 logicalToday()（消除凌晨假失败）**

以下 4 个既有测试把 `QDate::currentDate()` 当"服务的今天"用，服务切逻辑日后它们在凌晨 0-4 点运行会假失败。**在这 4 个函数体内把每处 `QDate::currentDate()` 整体替换为 `logicalToday()`**（函数内"今天"语义全部指服务口径，整体替换安全；显式日期自洽的其它测试一律不动）：

- `statisticsReturnsTodayCompletionAndDuration`（4 处）
- `getWeekStatsUsesCurrentNaturalWeek`（1 处）
- `getMonthStatsUsesCurrentMonthAndTaskDate`（1 处）
- `getMonthWeeklySummaryStaysInsideCurrentMonth`（1 处）

替换后核对：`awk '/^void ServiceTests::/{fn=$2} /QDate::currentDate/{print NR" "fn}' tests/ServiceTests.cpp | grep -E "statisticsReturnsToday|getWeekStatsUsesCurrent|getMonthStatsUsesCurrent|getMonthWeeklySummaryStays"` 应无输出。

- [ ] **Step 5: 跑测试（GREEN）+ 既有统计测试回归**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests statisticsBucketsSessionsByLogicalDay statisticsTodayUsesLogicalToday statisticsReturnsTodayCompletionAndDuration statisticsIgnoresInvalidShortSessions getWeekStatsUsesCurrentNaturalWeek getMonthStatsUsesCurrentMonthAndTaskDate getMonthWeeklySummaryStaysInsideCurrentMonth`
Expected: 7 passed（其余既有统计用例插的是 12:00 的 session 且用显式日期，逻辑日=物理日，不受影响）。

- [ ] **Step 6: 提交**

```bash
git add src/services/StatisticsService.cpp tests/ServiceTests.cpp
git commit -m "StatisticsService 分桶与今天全改逻辑日（四处SQL加dayShift+四处today+今天耦合用例改logicalToday）"
```

---

### Task 4: FocusHistoryService 改命名占位符 + 逻辑日

**Files:**
- Modify: `src/services/FocusHistoryService.h`
- Modify: `src/services/FocusHistoryService.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Consumes: `LogicalDay::sqlShift`、`AppSettings::dayStartHour`。
- Produces: `querySessions(const QString& whereClause /* 命名占位符 */, const QVariantMap& namedBinds)`；getMonthSessions/getDaySessions 及返回的 `date` 字段按逻辑日。

- [ ] **Step 1: 写失败测试**

private slots 加：

```cpp
    void focusHistoryBucketsSessionsByLogicalDay();
```

实现：

```cpp
void ServiceTests::focusHistoryBucketsSessionsByLogicalDay()
{
    AppSettings::instance()->setDayStartHour(4);
    FocusHistoryService* service = FocusHistoryService::instance();

    const QDate monthFirst(2026, 8, 1);
    const int taskId = insertTaskRow(QStringLiteral("跨月凌晨"), monthFirst);
    QVERIFY(taskId > 0);
    // 8月1日 01:00 的 session 逻辑日是 7月31日：应归 7 月，且 date 字段也须是逻辑日。
    QVERIFY(insertFocusSessionRowAt(taskId, monthFirst, QStringLiteral("01:00:00"), QStringLiteral("01:30:00"), 1800));

    const QVariantList julySessions = service->getMonthSessions(2026, 7);
    QCOMPARE(julySessions.size(), 1);
    QCOMPARE(julySessions.first().toMap().value(QStringLiteral("date")).toString(),
             QStringLiteral("2026-07-31"));
    QVERIFY(service->getMonthSessions(2026, 8).isEmpty());

    QCOMPARE(service->getDaySessions(QDate(2026, 7, 31)).size(), 1);
    QVERIFY(service->getDaySessions(monthFirst).isEmpty());
}
```

- [ ] **Step 2: 确认失败（RED）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests focusHistoryBucketsSessionsByLogicalDay`
Expected: FAIL——按物理日归 8 月。

- [ ] **Step 3: 实现**

`src/services/FocusHistoryService.h`：顶部加 `#include <QVariantMap>`；私有声明（约 29-30 行）改为：

```cpp
    // whereClause 只接收本类内部拼出的条件，用命名占位符（:shift 可复用）；
    // 外部值必须走 namedBinds，避免 SQL 拼接污染。命名绑定消除了 positional
    // 顺序脆弱——SELECT 里加 :shift 后 positional 索引会全部错位。
    QVariantList querySessions(const QString& whereClause,
                               const QVariantMap& namedBinds = QVariantMap()) const;
```

`src/services/FocusHistoryService.cpp`：include 区加：

```cpp
#include "AppSettings.h"
#include "LogicalDay.h"
```

`getMonthSessions`（约 48-49 行）末尾改：

```cpp
    return querySessions(QStringLiteral("date(fs.start_time, :shift) >= :startDate "
                                        "AND date(fs.start_time, :shift) < :endDate"),
                         QVariantMap{{QStringLiteral(":startDate"), startDate.toString(Qt::ISODate)},
                                     {QStringLiteral(":endDate"), nextMonthStart.toString(Qt::ISODate)}});
```

`getDaySessions`（约 60-61 行）末尾改：

```cpp
    return querySessions(QStringLiteral("date(fs.start_time, :shift) = :date"),
                         QVariantMap{{QStringLiteral(":date"), date.toString(Qt::ISODate)}});
```

`querySessions`（约 164 行起）：签名改 `const QVariantMap& namedBinds`；SELECT 里 `"date(fs.start_time) AS session_date "` 改 `"date(fs.start_time, :shift) AS session_date "`；绑定循环（约 207-209 行）替换为：

```cpp
    // :shift 在 SELECT 与 WHERE 多处复用、只绑一次；其余命名参数逐一绑定。
    query.bindValue(QStringLiteral(":shift"),
                    LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()));
    for (auto it = namedBinds.constBegin(); it != namedBinds.constEnd(); ++it) {
        query.bindValue(it.key(), it.value());
    }
```

- [ ] **Step 4: 跑测试（GREEN）+ 既有历史用例回归**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests focusHistoryBucketsSessionsByLogicalDay focusHistoryReturnsMonthSessionsWithinBoundaries focusHistoryReturnsDayTotalsAndFormattedDurations focusHistoryFallsBackWhenTaskWasDeleted focusHistoryDistinguishesEmptyResultFromQueryError focusHistorySkipsUnfinishedSessions focusHistorySkipsInvalidShortSessions focusHistoryCleansInvalidShortSessions`
Expected: 8 passed。

- [ ] **Step 5: 提交**

```bash
git add src/services/FocusHistoryService.h src/services/FocusHistoryService.cpp tests/ServiceTests.cpp
git commit -m "FocusHistoryService 改命名占位符并按逻辑日分桶（session_date 同口径）"
```

---

### Task 5: ExportService 导出范围按逻辑日

**Files:**
- Modify: `src/services/ExportService.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Consumes: `LogicalDay::sqlShift`、`AppSettings::dayStartHour`。
- Produces: `exportFocusSessions` 的日期范围过滤按逻辑日（与 UI 统计同口径）。

- [ ] **Step 1: 写失败测试**

private slots 加：

```cpp
    void exportFocusSessionsUsesLogicalDayRange();
```

实现：

```cpp
void ServiceTests::exportFocusSessionsUsesLogicalDayRange()
{
    AppSettings::instance()->setDayStartHour(4);
    const QDate day(2026, 7, 8);
    const int taskId = insertTaskRow(QStringLiteral("导出边界"), day, QStringLiteral("政治"));
    QVERIFY(taskId > 0);
    QVERIFY(insertFocusSessionRowAt(taskId, day, QStringLiteral("01:00:00"), QStringLiteral("01:30:00"), 1800));

    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 导出与 UI 统计同口径：01:00 的记录属于逻辑日 7月7日的导出范围。
    const QString hitPath = dir.filePath(QStringLiteral("hit.csv"));
    QVERIFY(ExportService::instance()->exportFocusSessions(day.addDays(-1), day.addDays(-1), hitPath));
    QFile hitFile(hitPath);
    QVERIFY(hitFile.open(QIODevice::ReadOnly | QIODevice::Text));
    QVERIFY(QString::fromUtf8(hitFile.readAll()).contains(QStringLiteral("导出边界")));

    // 物理日 7月8日的范围不应再含它。
    const QString missPath = dir.filePath(QStringLiteral("miss.csv"));
    QVERIFY(ExportService::instance()->exportFocusSessions(day, day, missPath));
    QFile missFile(missPath);
    QVERIFY(missFile.open(QIODevice::ReadOnly | QIODevice::Text));
    QVERIFY(!QString::fromUtf8(missFile.readAll()).contains(QStringLiteral("导出边界")));
}
```

- [ ] **Step 2: 确认失败（RED）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests exportFocusSessionsUsesLogicalDayRange`
Expected: FAIL——hit.csv 不含该记录。

- [ ] **Step 3: 实现**

`src/services/ExportService.cpp` include 区加：

```cpp
#include "AppSettings.h"
#include "LogicalDay.h"
```

`exportFocusSessionsToFile` 里 fromAndWhere（约 234-243 行）改为：

```cpp
    // shift 以字面量嵌入而非 :dayShift 绑定：countRows 与主查询共用这段 SQL、
    // 只绑 startDate/endDate，字面量避免两处各补绑定的分叉；值由归一化整点派生
    // （"-N hours"，N∈0..6），与 %2 的 minDuration 一样无注入面。口径=逻辑日，与统计一致。
    const QString fromAndWhere = QStringLiteral(
        "FROM focus_sessions f "
        "LEFT JOIN tasks t ON f.task_id = t.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "WHERE date(f.start_time, '%1') >= :startDate "
        "AND date(f.start_time, '%1') <= :endDate "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= %2")
                                     .arg(LogicalDay::sqlShift(AppSettings::instance()->dayStartHour()))
                                     .arg(FocusSessionRules::kMinimumValidDurationSeconds);
```

- [ ] **Step 4: 跑测试（GREEN）+ 既有导出回归**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests exportFocusSessionsUsesLogicalDayRange exportTasksWritesUtf8CsvWithEscapingAndCategoryFallbacks exportFocusSessionsAndExportAllWriteExpectedCsvFiles exportFocusSessionsIgnoresInvalidShortSessions exportRejectsInvalidDateRangeAndUnwritablePath`
Expected: 5 passed。

- [ ] **Step 5: 全量 SQL 口径核对（规格要求）**

Run: `grep -rn "date(.*start_time" src/ | grep -v "dayShift\|:shift\|'%1'"`
Expected: 无输出（所有 focus_sessions 取日期处都已带 shift）。

- [ ] **Step 6: 提交**

```bash
git add src/services/ExportService.cpp tests/ServiceTests.cpp
git commit -m "ExportService 导出范围按逻辑日过滤（与统计同口径）"
```

---

### Task 6: LogicalDayService（构造即排期）+ CMake + main.cpp 接线

**Files:**
- Create: `src/services/LogicalDayService.h`
- Create: `src/services/LogicalDayService.cpp`
- Modify: `CMakeLists.txt`
- Modify: `src/main.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Consumes: `LogicalDay::msUntilNextBoundary`、`AppSettings::dayStartHourChanged`。
- Produces: `LogicalDayService::instance()`、信号 `changed()`；边界 QTimer objectName `"logicalDayBoundaryTimer"`（测试契约）；上下文属性 `logicalDayService`；main.cpp 里 `changed → RoutineManager::materializeToday` 直连。

- [ ] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` include 区加：

```cpp
#include "../src/services/LogicalDayService.h"

#include <QTimer>
```

private slots 加：

```cpp
    void logicalDayServiceSchedulesTimerOnConstruction();
    void logicalDayServiceEmitsChangedOnDayStartHourChange();
    void logicalDayChangeMaterializesRoutineIdempotently();
```

实现：

```cpp
void ServiceTests::logicalDayServiceSchedulesTimerOnConstruction()
{
    // 构造即排期：不改任何设置也必须能跨 4 点自动失效。
    // objectName 是唯一约定的测试访问路径（私有成员 QTimer 无合法访问方式）。
    LogicalDayService service;
    auto* timer = service.findChild<QTimer*>(QStringLiteral("logicalDayBoundaryTimer"));
    QVERIFY(timer);
    QVERIFY(timer->isActive());
    QVERIFY(timer->remainingTime() > 0);
}

void ServiceTests::logicalDayServiceEmitsChangedOnDayStartHourChange()
{
    AppSettings::instance()->setDayStartHour(4);
    LogicalDayService service;
    QSignalSpy spy(&service, &LogicalDayService::changed);

    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(spy.count(), 1);

    // 同值写入不发信号 → 不应触发失效。
    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(spy.count(), 1);
}

void ServiceTests::logicalDayChangeMaterializesRoutineIdempotently()
{
    AppSettings::instance()->setDayStartHour(4);
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("失效补例行"), -1));

    // 复现 main.cpp 的接线：changed → materializeToday（直连，先于任何视图槽）。
    LogicalDayService service;
    connect(&service, &LogicalDayService::changed,
            RoutineManager::instance(), &RoutineManager::materializeToday);

    auto countRoutineTasks = []() {
        QSqlQuery query(DatabaseManager::instance()->database());
        if (!query.exec(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '失效补例行'"))
            || !query.next()) {
            return -1;
        }
        return query.value(0).toInt();
    };

    QCOMPARE(countRoutineTasks(), 0);

    // 触发失效 → 例行落库。
    AppSettings::instance()->setDayStartHour(5);
    QCOMPARE(countRoutineTasks(), 1);

    // 再次失效 → materializeToday 幂等，不重复插。
    AppSettings::instance()->setDayStartHour(6);
    QCOMPARE(countRoutineTasks(), 1);
}
```

- [ ] **Step 2: 确认编译失败（RED）**

Run: `cmake --build build 2>&1 | tail -5`
Expected: `LogicalDayService.h' file not found`。

- [ ] **Step 3: 创建服务**

`src/services/LogicalDayService.h`：

```cpp
#ifndef LOGICALDAYSERVICE_H
#define LOGICALDAYSERVICE_H

#include <QObject>

class QTimer;

// 逻辑日失效的统一信号源：改日界点设置、或到达逻辑午夜（dayStartHour 整点）时
// 发 changed()，已打开的视图/服务据此重载。定时器构造即排期——用户从不改设置
// 也必须能跨 4 点自动失效。
class LogicalDayService : public QObject
{
    Q_OBJECT

public:
    static LogicalDayService* instance();
    explicit LogicalDayService(QObject* parent = nullptr);

signals:
    void changed();

private slots:
    void onInvalidate();

private:
    void scheduleNextBoundary();

    QTimer* m_boundaryTimer = nullptr;
};

#endif // LOGICALDAYSERVICE_H
```

`src/services/LogicalDayService.cpp`：

```cpp
#include "LogicalDayService.h"

#include "AppSettings.h"
#include "LogicalDay.h"

#include <QDateTime>
#include <QTimer>

LogicalDayService* LogicalDayService::instance()
{
    static LogicalDayService service;
    return &service;
}

LogicalDayService::LogicalDayService(QObject* parent)
    : QObject(parent)
    , m_boundaryTimer(new QTimer(this))
{
    // objectName 是测试契约：私有定时器唯一合法的外部观察路径是 findChild。
    m_boundaryTimer->setObjectName(QStringLiteral("logicalDayBoundaryTimer"));
    m_boundaryTimer->setSingleShot(true);

    connect(m_boundaryTimer, &QTimer::timeout, this, &LogicalDayService::onInvalidate);
    connect(AppSettings::instance(), &AppSettings::dayStartHourChanged,
            this, &LogicalDayService::onInvalidate);

    // 构造即排期（只排期不发信号）：否则定时器要等首次 onInvalidate 才启动，
    // 不改设置就永不启动、跨 4 点不会发 changed()。
    scheduleNextBoundary();
}

void LogicalDayService::onInvalidate()
{
    emit changed();
    scheduleNextBoundary();
}

void LogicalDayService::scheduleNextBoundary()
{
    const qint64 ms = LogicalDay::msUntilNextBoundary(QDateTime::currentDateTime(),
                                                      AppSettings::instance()->dayStartHour());
    // 最长 24 小时（86,400,000ms），安全落在 int 内。
    m_boundaryTimer->start(static_cast<int>(ms));
}
```

- [ ] **Step 4: CMake 编入两目标**

`CMakeLists.txt`：

1）`set(APP_SOURCES` 列表里 `src/services/StatisticsService.cpp` 行后加：

```cmake
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
```

2）`add_executable(PomodoroTodoTests` 列表里 `src/services/AppSettings.cpp` 行后加：

```cmake
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
```

- [ ] **Step 5: main.cpp 接线**

`src/main.cpp`：

1）include 区（`#include "services/FocusTimer.h"` 附近）加：

```cpp
#include "services/LogicalDayService.h"
```

2）`RoutineManager::instance()->materializeToday();`（约 51 行）之后、`QQmlApplicationEngine engine;` 之前加：

```cpp
    // 逻辑日失效（改设置/跨逻辑午夜）→ 先补当日例行再让视图刷新。
    // 必须在 engine.load 前直连：changed() 同步派发时 materializeToday 先于任何 QML 槽执行，
    // 视图重查时新逻辑日的例行已落库。
    QObject::connect(LogicalDayService::instance(), &LogicalDayService::changed,
                     RoutineManager::instance(), &RoutineManager::materializeToday);
```

3）上下文属性区 `setContextProperty(QStringLiteral("appSettings"), ...)` 行后加：

```cpp
    engine.rootContext()->setContextProperty(QStringLiteral("logicalDayService"), LogicalDayService::instance());
```

- [ ] **Step 6: 跑测试（GREEN）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests logicalDayServiceSchedulesTimerOnConstruction logicalDayServiceEmitsChangedOnDayStartHourChange logicalDayChangeMaterializesRoutineIdempotently`
Expected: 3 passed。

- [ ] **Step 7: 提交**

```bash
git add src/services/LogicalDayService.h src/services/LogicalDayService.cpp CMakeLists.txt src/main.cpp tests/ServiceTests.cpp
git commit -m "新增 LogicalDayService 失效信号（构造即排期）并接线 main.cpp 例行补齐"
```

---

### Task 7: LogicalDay.js + qrc 注册 + QML 单测

**Files:**
- Create: `qml/LogicalDay.js`
- Modify: `resources/qml.qrc`
- Test: `tests/qml/tst_logical_day.qml`（新建）

**Interfaces:**
- Produces: `LogicalDay.todayDate(dayStartHour, nowDate) -> Date`（归零到 0 点）、`LogicalDay.todayIso(dayStartHour, nowDate) -> "yyyy-MM-dd"`。计划一 Task 8 与计划二全部 QML "今天"消费。

- [ ] **Step 1: 写失败测试（新建 `tests/qml/tst_logical_day.qml`）**

```qml
import QtQuick
import QtTest
import "../../qml/LogicalDay.js" as LogicalDay

// 全部用固定 nowDate：算法与系统时钟解耦，不模拟真实凌晨。
TestCase {
    name: "LogicalDay"

    function test_todayDateBoundaries() {
        // 2026-07-08 3:59（h=4）→ 逻辑日 7月7日；4:00 → 7月8日。
        compare(LogicalDay.todayDate(4, new Date(2026, 6, 8, 3, 59)).getTime(),
                new Date(2026, 6, 7).getTime())
        compare(LogicalDay.todayDate(4, new Date(2026, 6, 8, 4, 0)).getTime(),
                new Date(2026, 6, 8).getTime())
        // h=0 即物理日。
        compare(LogicalDay.todayDate(0, new Date(2026, 6, 8, 0, 30)).getTime(),
                new Date(2026, 6, 8).getTime())
        // 返回值必须归零到 0 点（供日期比较，不带时分）。
        compare(LogicalDay.todayDate(4, new Date(2026, 6, 8, 15, 42)).getHours(), 0)
    }

    function test_todayIsoBoundaries() {
        compare(LogicalDay.todayIso(4, new Date(2026, 6, 8, 1, 0)), "2026-07-07")
        compare(LogicalDay.todayIso(4, new Date(2026, 6, 8, 12, 0)), "2026-07-08")
        // 跨年 + 月/日补零。
        compare(LogicalDay.todayIso(4, new Date(2026, 0, 1, 2, 0)), "2025-12-31")
        compare(LogicalDay.todayIso(4, new Date(2026, 2, 5, 12, 0)), "2026-03-05")
    }
}
```

- [ ] **Step 2: 确认失败（RED）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_logical_day.qml`
Expected: FAIL（import 找不到 LogicalDay.js）。

- [ ] **Step 3: 创建 `qml/LogicalDay.js`**

```js
.pragma library

// 逻辑日（QML 侧）：dayStartHour（0-6 整点）前的凌晨归前一天。
// nowDate 必须显式传入——生产传 new Date()，测试传固定 Date，不硬依赖系统时钟。
// 需要 Date 的场景用 todayDate，需要 ISO 串的用 todayIso，二者不混用。

function todayDate(dayStartHour, nowDate) {
    var shifted = new Date(nowDate.getTime() - dayStartHour * 3600 * 1000)
    // 归零到当天 0 点：调用方拿它做日期比较，不能带时分残留。
    return new Date(shifted.getFullYear(), shifted.getMonth(), shifted.getDate())
}

function todayIso(dayStartHour, nowDate) {
    var d = todayDate(dayStartHour, nowDate)
    var month = d.getMonth() + 1
    var day = d.getDate()
    return d.getFullYear() + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
}
```

- [ ] **Step 4: qrc 注册（必须——资源表逐项列举，漏了则正式应用 import 失败而测试全绿）**

`resources/qml.qrc` 里 `<file alias="qml/Theme.qml">` 行后加：

```xml
        <file alias="qml/LogicalDay.js">../qml/LogicalDay.js</file>
```

- [ ] **Step 5: 跑测试（GREEN）+ lint**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_logical_day.qml`
Expected: 全绿。
Run: `cmake --build build 2>&1 | tail -3`
Expected: 通过（qrc 变更编译进包）。

- [ ] **Step 6: 提交**

```bash
git add qml/LogicalDay.js resources/qml.qrc tests/qml/tst_logical_day.qml
git commit -m "新增 QML LogicalDay.js（可注入 now 的逻辑日助手）并注册 qrc"
```

---

### Task 8: StatisticsView 时间源改逻辑今天 + 订阅失效

**Files:**
- Modify: `qml/views/StatisticsView.qml`
- Modify: `tests/qml/tst_phase2_layout.qml`（既有 provider 夹具改正午——见 Step 1 说明）
- Test: `tests/qml/tst_statistics_logical_day.qml`（新建）

**Interfaces:**
- Consumes: Task 7 `LogicalDay.todayDate`；Task 6 上下文属性 `logicalDayService`。
- Produces: `refreshCurrentDateSnapshot()` 快照=逻辑今天（provider 注入值同样换算）；`Connections` 订阅 `logicalDayService.changed` → 只调 `refresh()`。

- [ ] **Step 1: 先改既有夹具（否则 Step 4 改完源码它必挂）**

`tests/qml/tst_phase2_layout.qml` 的 provider 现返回**午夜 0 点**日期；快照过逻辑日换算（h=4，该文件无 appSettings mock → 守卫默认 4）后会整体前移一天。把 provider 包一层正午即可保持"模拟今天"语义（0 点 < 任何合法界点 ≤ 6 点，正午恒安全）：

1）`dateOnly` 函数（约 274 行）旁加：

```qml
    function noonOf(value) {
        // 模拟"现在"统一用正午：任何合法日界点(0-6)下正午都归当天，夹具语义不随 h 漂移。
        var date = new Date(value)
        date.setHours(12, 0, 0, 0)
        return date
    }
```

2）`init()`（约 256 行）里：

```qml
        statisticsView.currentDateProvider = function() {
            return todaySnapshot
        }
```

改为：

```qml
        statisticsView.currentDateProvider = function() {
            return noonOf(todaySnapshot)
        }
```

3）`test_statisticsRefreshTracksCurrentPeriodAfterDateSnapshotChanges`（约 787 行）里：

```qml
        statisticsView.currentDateProvider = function() {
            return providedDate
        }
```

改为：

```qml
        statisticsView.currentDateProvider = function() {
            return noonOf(providedDate)
        }
```

（该测试后续所有 `providedDate = ...` 赋值与断言不动——正午换算后仍是同一日历日。）

- [ ] **Step 2: 写失败测试（新建 `tests/qml/tst_statistics_logical_day.qml`）**

```qml
import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "StatisticsLogicalDay"
    when: windowShown
    width: 900
    height: 700

    property int dayStatsCalls: 0

    // 视图内未限定名按文档作用域解析到这些 mock（项目既有惯例）。
    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: statisticsService

        function getDayStats(day) {
            testCase.dayStatsCalls++
            return { totalDuration: 0, completedTasks: 0, totalTasks: 0, completionRate: 0, sessionCount: 0 }
        }
        function getDayComparison(day) { return {} }
        function getWeekStats(start) { return [] }
        function getCategoryStats(startIso, endIso) { return { categories: [], totalDuration: 0 } }
    }

    StatisticsView {
        id: view

        width: 900
        height: 700
        // 注入固定凌晨 1 点：证明 provider 返回值也过了逻辑日换算，而非只换默认 new Date()。
        currentDateProvider: function() {
            return new Date(2026, 6, 8, 1, 0)
        }
    }

    function init() {
        view.currentTimeRange = "today"
        view.refreshCurrentDateSnapshot()
        view.applyCurrentPeriodSelection()
        testCase.dayStatsCalls = 0
    }

    function test_snapshotIsLogicalToday() {
        // 7月8日 01:00、h=4 → 逻辑今天 = 7月7日。
        compare(Qt.formatDate(view.currentDateSnapshot, "yyyy-MM-dd"), "2026-07-07")
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
    }

    function test_changedTriggersRefreshAndKeepsHistoricalSelection() {
        // 用户翻到历史日后跨日界：只 refresh，不得把用户拉回当前期。
        view.selectedDate = new Date(2026, 5, 1)
        var callsBefore = testCase.dayStatsCalls

        logicalDayService.changed()

        verify(testCase.dayStatsCalls > callsBefore)
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-06-01")
    }

    function test_changedFollowsCurrentPeriod() {
        // 停在当前期（选中=逻辑今天）时，refresh 内的 sync 逻辑应跟随快照。
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
        logicalDayService.changed()
        compare(Qt.formatDate(view.selectedDate, "yyyy-MM-dd"), "2026-07-07")
    }
}
```

- [ ] **Step 3: 确认失败（RED）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_statistics_logical_day.qml`
Expected: `test_snapshotIsLogicalToday` FAIL（快照是物理 7月8日）；`test_changedTriggersRefresh...` FAIL（无订阅，refresh 未被调）。

- [ ] **Step 4: 实现**

`qml/views/StatisticsView.qml`：

1）import 区（`import "StatisticsFormat.js" as StatFmt` 后）加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）`refreshCurrentDateSnapshot()`（约 127-131 行）整函数替换：

```qml
    function refreshCurrentDateSnapshot() {
        var providedDate = root.currentDateProvider ? root.currentDateProvider() : new Date()
        var normalizedDate = new Date(providedDate)
        if (isNaN(normalizedDate.getTime())) {
            normalizedDate = new Date()
        }
        // provider 注入值与默认值都过逻辑日换算：快照必须是"逻辑今天"，
        // 否则凌晨窗口统计页选中物理今天，与 getTodayStats 的逻辑今天口径打架。
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        currentDateSnapshot = LogicalDay.todayDate(h, normalizedDate)
    }
```

3）既有 `Connections`（categoriesChanged 订阅，约 118-125 行）之后加：

```qml
    Connections {
        // 逻辑日失效（改日界点/跨逻辑午夜）→ 只 refresh：refresh 内的
        // syncCurrentDateSnapshotForRefresh 已实现"停在当前期才跟随、历史期保留"。
        // 不要调 resetSelectedPeriodToCurrent——它是给"今日/本周/本月"菜单用的无条件重置，
        // 会把浏览历史期的用户强制拉走。
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            root.refresh()
        }
    }
```

- [ ] **Step 5: 跑测试（GREEN）×2 + 既有回归 + lint**

Run（各 ×2）:
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_statistics_logical_day.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_phase2_layout.qml`
Expected: 全绿 ×2（phase2 既有偶发按基线重跑区分）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/StatisticsView.qml`
Expected: 不新增警告。

- [ ] **Step 6: 提交**

```bash
git add qml/views/StatisticsView.qml tests/qml/tst_phase2_layout.qml tests/qml/tst_statistics_logical_day.qml
git commit -m "StatisticsView 时间源改逻辑今天并订阅失效信号（provider 同样换算/夹具改正午）"
```

---

### Task 9: 设置弹窗"每日起始时间"步进器

**Files:**
- Modify: `qml/components/SettingsDialog.qml`
- Test: `tests/qml/tst_settings_dialog.qml`

**Interfaces:**
- Consumes: Task 1 `appSettingsRef.dayStartHour`；既有 `DurationStepper`（value/from/to/namePrefix + adjusted，子控件名 `namePrefix+Minus/Value/Plus`）。
- Produces: objectName `settingsDayStartRow` / `settingsDayStartMinus` / `settingsDayStartValue` / `settingsDayStartPlus`。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_settings_dialog.qml`：

1）`appSettingsMock`（约 15-22 行）加属性：

```qml
        property int dayStartHour: 4
```

2）`init()`（约 36 行）里 `appSettingsMock.slimClockFont = true` 后加：

```qml
        appSettingsMock.dayStartHour = 4
```

3）TestCase 的 `height: 820`（约 13 行）改为 `height: 880`，注释同步改：

```qml
    // 四段偏好 + 管理行更高：给足高度让弹窗不触发滚动裁剪，管理行才在视口内可被 mouseClick 命中
    // （520px 下的滚动到关闭属人工冒烟验收，不在此单测覆盖）。
    height: 880
```

4）文件末尾（`test_dialogUsesWideReferenceLayout` 后）加：

```qml
    function test_dayStartStepperBindsAndWrites() {
        dialog.open()
        wait(20)

        verify(findChild(dialog, "settingsDayStartRow"))
        var valueText = findChild(dialog, "settingsDayStartValue")
        verify(valueText)
        compare(valueText.text, "4")

        mouseClick(findChild(dialog, "settingsDayStartPlus"))
        compare(appSettingsMock.dayStartHour, 5)
        compare(valueText.text, "5")

        mouseClick(findChild(dialog, "settingsDayStartMinus"))
        compare(appSettingsMock.dayStartHour, 4)
    }

    function test_dayStartStepperMissingSettingsRefIsNoop() {
        dialog.appSettingsRef = null
        dialog.open()
        wait(20)

        mouseClick(findChild(dialog, "settingsDayStartPlus"))
        compare(appSettingsMock.dayStartHour, 4)
    }
```

- [ ] **Step 2: 确认失败（RED）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`
Expected: 两个新用例 FAIL（settingsDayStartRow 不存在），其余全绿。

- [ ] **Step 3: 实现**

`qml/components/SettingsDialog.qml`，"偏好" SectionGroup 内、纤细计时字体 `PreferenceSwitchRow`（约 307-317 行）之后加：

```qml
                RowDivider {
                    objectName: "settingsPreferenceDividerDayStart"
                }

                // 每日起始时间：凌晨此点前的活动归前一天（熬夜自习不被劈成两天）。
                // 结构对齐 PreferenceSwitchRow（左标签+副说明、右控件），但右侧是步进器不是开关。
                Rectangle {
                    objectName: "settingsDayStartRow"
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.space12
                    Layout.rightMargin: Theme.space12
                    implicitHeight: 64
                    color: "transparent"

                    Column {
                        anchors.left: parent.left
                        anchors.right: dayStartStepper.left
                        anchors.leftMargin: Theme.space12
                        anchors.rightMargin: Theme.space12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: "每日起始时间"
                            textFormat: Text.PlainText
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd
                        }

                        Text {
                            text: "凌晨此点前算前一天（4 = 凌晨4点）"
                            textFormat: Text.PlainText
                            color: Theme.inkMuted
                            font.pixelSize: Theme.fontSm
                        }
                    }

                    DurationStepper {
                        id: dayStartStepper

                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space12
                        anchors.verticalCenter: parent.verticalCenter
                        from: 0
                        to: 6
                        value: root.appSettingsRef ? root.appSettingsRef.dayStartHour : 4
                        namePrefix: "settingsDayStart"
                        onAdjusted: function (newValue) {
                            // 缺 appSettingsRef（测试/降级）时不写，同其它偏好行守卫。
                            if (root.appSettingsRef) {
                                root.appSettingsRef.dayStartHour = newValue
                            }
                        }
                    }
                }
```

- [ ] **Step 4: 跑测试（GREEN）×2 + lint**

Run（×2）: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_settings_dialog.qml`
Expected: 全绿 ×2（`test_preferenceSwitchesAlignToGroupRightEdge` 偶发按既有基线重跑区分）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/SettingsDialog.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/components/SettingsDialog.qml tests/qml/tst_settings_dialog.qml
git commit -m "设置弹窗新增每日起始时间步进器（0-6，写 dayStartHour）"
```

---

### Task 10: 全量无头回归 + 汇报

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量回归 ×2**

Run（×2）: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 全部通过（既有 offscreen 偶发用例按基线重跑区分，非本改动引入的必须稳定绿）。

- [ ] **Step 2: 汇报**

汇报：专注归日全口径统一（Statistics 4 处 + FocusHistory 命名重构 + Export，`grep date(.*start_time` 零残留）、LogicalDayService 构造即排期 + 例行补齐接线、统计页时间源=逻辑今天 + 订阅失效、设置可调 0-6。等待用户确认后进入计划二（任务/例行/倒计时/周计划/QML 今天）。**不自行合并回 main。**
