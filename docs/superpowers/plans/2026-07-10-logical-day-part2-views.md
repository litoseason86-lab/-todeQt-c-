# 逻辑日界点 · 计划二（任务/倒计时/周计划/QML 今天 + 视图失效订阅）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把全 app 剩余的"今天"统一到逻辑日：TaskManager（今日任务/结转）、倒计时三条 daysRemaining 路径（分层注入基准日 + primaryGoalChanged 通知）、QML 各"今天"入口（Today/AddTask/EditTask/Export/Countdown/Week/Month），并让 Today/Week/Month/Countdown 订阅 `logicalDayService.changed` 实现"当前期跟随、历史期保留"的跨日/改设置自动刷新。

**Architecture:** C++ 服务在调用点读 `AppSettings::instance()->dayStartHour()` 传给 `LogicalDay::today(h)`；**model 层零单例依赖**——CountdownGoal 改纯函数 `daysRemainingFrom(base)`、CountdownModel 注入 `m_referenceDate`、CountdownService 私有 `syncReferenceDate()` 统一推送并触发 `primaryGoalChanged`。QML 侧 Week/Month 落**命令式状态 `logicalToday`**（非绑定）+ `logicalNowProvider` 注入时间，`onChanged` 按六步固定顺序（prev→wasFollowing→next→赋值→移动→refresh）。

**Tech Stack:** Qt 6.9 / C++17 / SQLite / QML / Qt Test / qmltestrunner

**Depends on:** 计划一已完成（`LogicalDay.h`、`LogicalDay.js`（含 qrc）、`AppSettings.dayStartHour`、`RoutineManager::materializeToday()` 已按逻辑日生成、`LogicalDayService` + 上下文属性、ServiceTests 的 `insertFocusSessionRowAt`/`logicalToday()` helper 均已存在）。继续在分支 `logical-day` 上执行。

## Global Constraints

- 注释、提交说明中文，解释为什么/边界。
- 自动流程无头，禁 `open`。C++：`cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests <函数名>`（CountdownServiceTests 同法）；QML：`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<文件>`。
- QML 测试**永不断言 `visible === true`**；断言驱动属性。
- QML 取 hour 固定就地守卫：`(typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4`，配 `// qmllint disable unqualified`。
- **`logicalToday` 是命令式状态，不得写成绑定**；`weekStart`/月历年月选中日**不得绑定到 logicalToday**（顺序契约见规格失效节）。
- QML 订阅统一 `Connections { target: typeof logicalDayService !== "undefined" ? logicalDayService : null; ignoreUnknownSignals: true }`。
- 测试注入时间用**固定 provider 函数读可变 `fakeNow`**，不中途替换 provider 函数本身（换函数会提前触发属性变化）。
- 新/改 QML 文件 qmllint 不新增警告。

---

### Task 1: TaskManager 的今天改逻辑日

**Files:**
- Modify: `src/services/TaskManager.cpp`
- Test: `tests/ServiceTests.cpp`

**Interfaces:**
- Consumes: `LogicalDay::today(int)`、`AppSettings::dayStartHour()`、测试 helper `logicalToday()`（计划一 Task 3 已加）。
- Produces: `getTodayTasks()`/overdue 判定/`moveTasksToToday` 的"今天"= 逻辑今天。RoutineManager 已在计划一完成，避免计划一的“失效补例行”连接只接到物理日实现。

- [ ] **Step 1: 写失败测试**

`tests/ServiceTests.cpp` private slots 加：

```cpp
    void taskManagerTodayUsesLogicalToday();
```

实现（加在既有任务管理测试之后）：

```cpp
void ServiceTests::taskManagerTodayUsesLogicalToday()
{
    // 薄包装只验证等价于 LogicalDay::today(h) 的显式日期查询，不模拟真实凌晨。
    AppSettings::instance()->setDayStartHour(4);
    TaskManager* manager = TaskManager::instance();

    QVERIFY(manager->addTask(QStringLiteral("逻辑今日任务"), QVariant(logicalToday()), QString()));
    QVERIFY(manager->addTask(QStringLiteral("逻辑昨日任务"), QVariant(logicalToday().addDays(-1)), QString()));

    QCOMPARE(manager->getTodayTasks(), manager->getTasksByDate(logicalToday()));
    QCOMPARE(manager->getTodayTasks().size(), 1);

    // 结转判定同口径：逻辑昨日的未完成任务是逾期，逻辑今日的不是。
    const QVariantList overdue = manager->getOverdueUncompletedTasks();
    QCOMPARE(overdue.size(), 1);
    QCOMPARE(overdue.first().toMap().value(QStringLiteral("title")).toString(),
             QStringLiteral("逻辑昨日任务"));

    // 结转落到逻辑今天。
    QVERIFY(manager->moveTasksToToday(QVariantList{overdue.first().toMap().value(QStringLiteral("id"))}));
    QCOMPARE(manager->getTasksByDate(logicalToday()).size(), 2);
    QVERIFY(manager->getOverdueUncompletedTasks().isEmpty());
}

```

- [ ] **Step 2: 确认现状（凌晨窗口外两者等价，测试可能先绿）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests taskManagerTodayUsesLogicalToday`
Expected: 白天运行时可能已通过（逻辑今天=物理今天）——该测试锁定包装契约；核心日期算法的 RED/GREEN 已由计划一 LogicalDay 纯函数测试覆盖。继续 Step 3。

- [ ] **Step 3: 实现（3 处替换）**

`src/services/TaskManager.cpp` include 区加：

```cpp
#include "AppSettings.h"
#include "LogicalDay.h"
```

1）`getTodayTasks`（约 352 行）：

```cpp
    return getTasksByDate(LogicalDay::today(AppSettings::instance()->dayStartHour()));
```

2）overdue 查询绑定（约 471 行）：

```cpp
    query.bindValue(QStringLiteral(":today"),
                    LogicalDay::today(AppSettings::instance()->dayStartHour()).toString(Qt::ISODate));
```

3）`moveTasksToToday`（约 502 行）：

```cpp
    const QString today = LogicalDay::today(AppSettings::instance()->dayStartHour()).toString(Qt::ISODate);
```

- [ ] **Step 4: 既有"今天"耦合用例改 logicalToday()（消除凌晨假失败）**

以下 2 个既有测试把 `QDate::currentDate()` 当"服务的今天"用，实现改后凌晨 0-4 点运行会假失败。**在这些函数体内把每处 `QDate::currentDate()` 整体替换为 `logicalToday()`**（显式日期自洽的其它测试一律不动）：

- `overdueQueryExcludesTodayCompletedAndRoutine`（1 处，含由它派生的 yesterday）
- `moveTasksToTodayIsTransactional`（1 处，含由它派生的 yesterday）

替换后核对：`awk '/^void ServiceTests::/{fn=$2} /QDate::currentDate/{print NR" "fn}' tests/ServiceTests.cpp | grep -E "overdueQuery|moveTasksToToday"` 应无输出。

- [ ] **Step 5: 跑测试（GREEN）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/PomodoroTodoTests taskManagerTodayUsesLogicalToday overdueQueryExcludesTodayCompletedAndRoutine moveTasksToTodayIsTransactional`
Expected: 3 passed。

- [ ] **Step 6: 提交**

```bash
git add src/services/TaskManager.cpp tests/ServiceTests.cpp
git commit -m "任务管理的今天改逻辑日（今日任务/逾期判定/moveTasksToToday）"
```

---

### Task 2: 倒计时分层（daysRemainingFrom + referenceDate + syncReferenceDate + 通知）

**Files:**
- Modify: `src/models/CountdownGoal.h`、`src/models/CountdownGoal.cpp`
- Modify: `src/models/CountdownModel.h`、`src/models/CountdownModel.cpp`
- Modify: `src/services/CountdownService.h`、`src/services/CountdownService.cpp`
- Modify: `CMakeLists.txt`（CountdownServiceTests 目标）
- Test: `tests/CountdownServiceTests.cpp`

**Interfaces:**
- Consumes: `LogicalDay::today`、`AppSettings::dayStartHour`、`LogicalDayService::changed`。
- Produces: `CountdownGoal::daysRemainingFrom(const QDate&) const`（**删除** `daysRemaining()`）；`CountdownModel::setReferenceDate(const QDate&)`（对 DaysRemainingRole 发 dataChanged）；`CountdownService::syncReferenceDateTo(const QDate&)`（公开：同步 model + 横幅 + 通知的唯一实现）与私有槽 `syncReferenceDate()`（取逻辑今天后调它）。

- [ ] **Step 1: CMake 先编入依赖（否则测试目标链接失败）**

`CMakeLists.txt` 的 `add_executable(CountdownServiceTests` 源列表里 `src/services/CountdownService.cpp` 行后加：

```cmake
    src/services/AppSettings.h
    src/services/AppSettings.cpp
    src/services/LogicalDay.h
    src/services/LogicalDayService.h
    src/services/LogicalDayService.cpp
```

- [ ] **Step 2: 写失败测试**

`tests/CountdownServiceTests.cpp`：

1）include 区加：

```cpp
#include "../src/services/AppSettings.h"
#include "../src/services/LogicalDay.h"
```

2）`init()`（约 75 行）改为（基准日跨用例自愈——`syncReferenceDateTo` 会被测试改走，必须复位）：

```cpp
void CountdownServiceTests::init()
{
    clearGoals();
    AppSettings::instance()->setDayStartHour(4);
    CountdownService::instance()->syncReferenceDateTo(
        LogicalDay::today(AppSettings::instance()->dayStartHour()));
}
```

3）private slots 加：

```cpp
    void modelReferenceDateDrivesDaysRemaining();
    void syncReferenceDateUpdatesBothPathsAndNotifies();
```

4）实现（文件末尾 `QTEST_MAIN` 前）：

```cpp
void CountdownServiceTests::modelReferenceDateDrivesDaysRemaining()
{
    CountdownService* service = CountdownService::instance();
    const QDate reference = LogicalDay::today(AppSettings::instance()->dayStartHour());
    QVERIFY(service->addGoal(QStringLiteral("参考日目标"), reference.addDays(10)));

    CountdownModel* model = service->model();
    QSignalSpy dataSpy(model, &QAbstractItemModel::dataChanged);

    // 基准日注入是确定性的：不读时钟、不碰单例。
    model->setReferenceDate(reference.addDays(7));
    QCOMPARE(model->data(model->index(0), CountdownModel::DaysRemainingRole).toInt(), 3);
    QCOMPARE(dataSpy.count(), 1);

    // 同值不重复发 dataChanged。
    model->setReferenceDate(reference.addDays(7));
    QCOMPARE(dataSpy.count(), 1);
}

void CountdownServiceTests::syncReferenceDateUpdatesBothPathsAndNotifies()
{
    CountdownService* service = CountdownService::instance();
    const QDate reference = LogicalDay::today(AppSettings::instance()->dayStartHour());
    QVERIFY(service->addGoal(QStringLiteral("双路径目标"), reference.addDays(30)));

    QSignalSpy primarySpy(service, &CountdownService::primaryGoalChanged);

    // 直接驱动同步实现拿确定性基准日（生产槽 syncReferenceDate 只是取逻辑今天后调它；
    // 靠改 dayStartHour 换基准日只有凌晨 0-6 点才生效，测试不可依赖真实时钟）。
    service->syncReferenceDateTo(reference.addDays(7));

    // 三断言缺一不可：列表角色、横幅 map、通知——防"列表更新了横幅没更新"。
    QCOMPARE(service->model()->data(service->model()->index(0),
                                    CountdownModel::DaysRemainingRole).toInt(), 23);
    QCOMPARE(service->primaryGoal().toMap().value(QStringLiteral("daysRemaining")).toInt(), 23);
    QCOMPARE(primarySpy.count(), 1);
}
```

5）既有断言改基准日口径（服务基准日=逻辑今天，凌晨运行 `QDate::currentDate()` 会差一天）：

`primaryGoalReturnsQmlReadableMap` 里两处（约 311、318 行）：

```cpp
    QCOMPARE(primary.value(QStringLiteral("daysRemaining")).toInt(),
             int(LogicalDay::today(AppSettings::instance()->dayStartHour()).daysTo(firstDate)));
```

（第二处同法用 `secondDate`。）

`calculateDaysRemainingHandlesPastAndInvalidDates`（约 328 行）：

```cpp
    const QDate today = LogicalDay::today(AppSettings::instance()->dayStartHour());
```

- [ ] **Step 3: 确认编译失败（RED）**

Run: `cmake --build build 2>&1 | tail -5`
Expected: `no member named 'syncReferenceDateTo'` / `no member named 'setReferenceDate'`。

- [ ] **Step 4: 实现——CountdownGoal（纯值对象，src/models 不碰单例）**

`src/models/CountdownGoal.h`（约 43 行）：

```cpp
    int daysRemaining() const;
```

改为：

```cpp
    // 纯函数：基准日由调用方注入。model 层不得反向依赖 AppSettings/服务单例，
    // 否则污染模型测试与复用；"今天"的口径决策留在 service 层。
    int daysRemainingFrom(const QDate& baseDate) const;
```

`src/models/CountdownGoal.cpp`（约 80-87 行）整函数替换：

```cpp
int CountdownGoal::daysRemainingFrom(const QDate& baseDate) const
{
    if (!m_targetDate.isValid() || !baseDate.isValid()) {
        return 0;
    }

    return baseDate.daysTo(m_targetDate);
}
```

（`daysRemaining()` 已删；残留调用会编译失败，正好逼出全部改点。）

- [ ] **Step 5: 实现——CountdownModel 注入基准日**

`src/models/CountdownModel.h`：public 里 `moveGoal` 声明后加：

```cpp
    void setReferenceDate(const QDate& referenceDate);
```

private 里加：

```cpp
    // 默认物理今天：模型独立使用时行为不变；服务构造时立即用逻辑今天覆盖。
    QDate m_referenceDate = QDate::currentDate();
```

（顶部需 `#include <QDate>`——`CountdownGoal.h` 已带入，无需重复。）

`src/models/CountdownModel.cpp`：

1）`data()` 的 DaysRemainingRole（约 34 行）：

```cpp
    case DaysRemainingRole:
        return goal.daysRemainingFrom(m_referenceDate);
```

2）文件末尾加：

```cpp
void CountdownModel::setReferenceDate(const QDate& referenceDate)
{
    if (m_referenceDate == referenceDate) {
        return;
    }

    m_referenceDate = referenceDate;
    if (!m_goals.isEmpty()) {
        // 只失效 DaysRemainingRole：基准日变化不影响名称/日期/排序。
        emit dataChanged(index(0), index(m_goals.count() - 1), {DaysRemainingRole});
    }
}
```

- [ ] **Step 6: 实现——CountdownService 同步基准日 + 通知**

`src/services/CountdownService.h`：

1）public 里 `calculateDaysRemaining` 声明后加：

```cpp
    // 同步基准日的唯一实现：写 model、刷横幅缓存（map 变化时发 primaryGoalChanged）。
    // 公开是为了让测试注入确定性基准日；生产代码只经 syncReferenceDate() 走它。
    void syncReferenceDateTo(const QDate& referenceDate);
```

2）private 里 `updatePrimaryGoal();` 声明后加：

```cpp
    void syncReferenceDate();
```

成员区 `QVariantMap m_primaryGoalCache;` 前加：

```cpp
    QDate m_referenceDate;
```

（头文件需 `#include <QDate>`，若尚无。）

`src/services/CountdownService.cpp`：

1）include 区加：

```cpp
#include "AppSettings.h"
#include "LogicalDay.h"
#include "LogicalDayService.h"
```

2）构造函数（约 27-35 行）改为：

```cpp
CountdownService::CountdownService(QObject* parent)
    : QObject(parent)
    , m_model(new CountdownModel(this))
{
    // 先定基准日再加载：loadGoals → updatePrimaryGoal 生成的 map 必须已是逻辑今天口径。
    syncReferenceDate();

    // 只连 logicalDayService.changed 一处：它已覆盖"改 dayStartHour"与"跨逻辑午夜"两种失效
    // （dayStartHourChanged 由 LogicalDayService 转发），再连 dayStartHourChanged 会双触发。
    connect(LogicalDayService::instance(), &LogicalDayService::changed,
            this, &CountdownService::syncReferenceDate);

    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (db.isOpen() && initializeDatabase()) {
        loadGoals();
    }
}
```

3）`calculateDaysRemaining`（约 239-246 行）：

```cpp
int CountdownService::calculateDaysRemaining(const QDate& targetDate) const
{
    if (!targetDate.isValid()) {
        return 0;
    }

    return m_referenceDate.daysTo(targetDate);
}
```

4）`loadGoals` 末尾（约 324 行）的 `updatePrimaryGoal();` 改为：

```cpp
    // 重新加载（含换库重初始化）后重推基准日；内部会 updatePrimaryGoal。
    syncReferenceDate();
```

5）`goalToVariantMap`（约 381 行）：

```cpp
    map.insert(QStringLiteral("daysRemaining"), goal.daysRemainingFrom(m_referenceDate));
```

6）文件末尾加两函数：

```cpp
void CountdownService::syncReferenceDateTo(const QDate& referenceDate)
{
    m_referenceDate = referenceDate;
    // 列表与横幅吃同一基准日：漏掉任何一路就会"列表更新了横幅还是旧天数"。
    m_model->setReferenceDate(referenceDate);
    updatePrimaryGoal();
}

void CountdownService::syncReferenceDate()
{
    syncReferenceDateTo(LogicalDay::today(AppSettings::instance()->dayStartHour()));
}
```

- [ ] **Step 7: 全项目残留核对**

Run: `grep -rn "daysRemaining()" src/ tests/`
Expected: 无输出（QML 的 `daysRemaining` 是角色名/map 键，不受影响）。

- [ ] **Step 8: 跑测试（GREEN）**

Run: `cmake --build build && QT_QPA_PLATFORM=offscreen ./build/CountdownServiceTests`
Expected: 全部通过（含既有 10 用例 + 新 2 用例）。

- [ ] **Step 9: 提交**

```bash
git add src/models/CountdownGoal.h src/models/CountdownGoal.cpp src/models/CountdownModel.h src/models/CountdownModel.cpp src/services/CountdownService.h src/services/CountdownService.cpp CMakeLists.txt tests/CountdownServiceTests.cpp
git commit -m "倒计时分层改注入基准日（daysRemainingFrom+referenceDate+syncReferenceDate双路径同步+primaryGoalChanged）"
```

---

### Task 3: QML 对话框与今日页的"今天"改逻辑日

**Files:**
- Modify: `qml/views/TodayTaskView.qml`
- Modify: `qml/components/AddTaskDialog.qml`
- Modify: `qml/components/EditTaskDialog.qml`
- Modify: `qml/components/ExportDialog.qml`
- Modify: `qml/components/CountdownDialog.qml`
- Test: `tests/qml/tst_countdown_ui.qml`

**Interfaces:**
- Consumes: `LogicalDay.todayDate/todayIso`（计划一 Task 7）。
- Produces: 结转横幅"今天"、新任务默认日期、编辑"今天/明天/后天"、导出快捷范围、目标倒计时空值回落与默认 30 天后全部以逻辑今天为锚。

**源码补漏：** 规格的 QML 映射表没有列 `CountdownDialog`，但现状 `dateToInput()` 空值回落和 `openForAdd()` 默认 30 天后分别直接读取 `new Date()` / `Date.now()`。不改会导致凌晨窗口里倒计时新增目标仍比全 app 多一天，因此本任务把它作为必须项补入，而不是留作无关扩展。

- [ ] **Step 1: TodayTaskView 的 todayIsoDate**

`qml/views/TodayTaskView.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）`todayIsoDate()`（约 81-83 行）整函数替换：

```qml
    function todayIsoDate() {
        // 结转"今天忽略"与 overdue 判定必须同口径：都用逻辑今天。
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayIso(h, new Date());
    }
```

3）AddTaskDialog 实例（约 613 行）删掉这一行：

```qml
        selectedDate: new Date()
```

（组件默认值即将改成逻辑今天——单一来源，实例覆盖会把它顶回物理日。）

- [ ] **Step 2: AddTaskDialog 默认日期**

`qml/components/AddTaskDialog.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）`property date selectedDate: new Date()`（约 69 行）改为：

```qml
    property date selectedDate: {
        // 新任务默认落在逻辑今天：凌晨 1 点建的任务应属于"今晚这一天"。
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(h, new Date())
    }
```

- [ ] **Step 3: EditTaskDialog 今天/明天/后天**

`qml/components/EditTaskDialog.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）`isoWithOffset`（约 38-42 行）整函数替换：

```qml
    function isoWithOffset(offset) {
        // 快捷 chip 的"今天"以逻辑今天为基准，与今日页/结转一致。
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        var d = LogicalDay.todayDate(h, new Date());
        d.setDate(d.getDate() + offset);
        return Qt.formatDate(d, "yyyy-MM-dd");
    }
```

- [ ] **Step 4: ExportDialog 快捷范围**

`qml/components/ExportDialog.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）`mondayOf` 函数（约 85 行）前加本地函数（文件内 4 个调用点共用；函数体内就地守卫，不是把 appSettings 当参数传的那种危险封装）：

```qml
    function logicalToday() {
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(h, new Date())
    }
```

3）四个快捷范围函数（约 94-114 行）整体替换：

```qml
    function setDateRangeThisWeek() {
        startDateInput.text = Qt.formatDate(mondayOf(logicalToday()), "yyyy-MM-dd")
        endDateInput.text = Qt.formatDate(logicalToday(), "yyyy-MM-dd")
    }

    function setDateRangeThisMonth() {
        var today = logicalToday()
        startDateInput.text = Qt.formatDate(new Date(today.getFullYear(), today.getMonth(), 1), "yyyy-MM-dd")
        endDateInput.text = Qt.formatDate(today, "yyyy-MM-dd")
    }

    function setDateRangeLastMonth() {
        var today = logicalToday()
        startDateInput.text = Qt.formatDate(new Date(today.getFullYear(), today.getMonth() - 1, 1), "yyyy-MM-dd")
        endDateInput.text = Qt.formatDate(new Date(today.getFullYear(), today.getMonth(), 0), "yyyy-MM-dd")
    }

    function setDateRangeAll() {
        startDateInput.text = "2020-01-01"
        endDateInput.text = Qt.formatDate(logicalToday(), "yyyy-MM-dd")
    }
```

（`property date currentDate`（11 行）无任何读取点，属死属性，不动不删——本计划不做无关清理。）

- [ ] **Step 5: CountdownDialog 的日期回落与“默认 30 天后”改逻辑日，并补固定时间测试**

`qml/components/CountdownDialog.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）属性区加测试可控时间源：

```qml
    // 仅测试注入；生产为 null 时读取真实现在。
    property var logicalNowProvider: null
```

3）`dateToInput()` 前加本地逻辑今天函数，并把空值回落改为逻辑今天：

```qml
    function logicalToday() {
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(h, now)
    }

    function dateToInput(value) {
        return Qt.formatDate(value ? value : root.logicalToday(), "yyyy-MM-dd")
    }
```

4）`openForAdd()` 中物理 `Date.now() + 30天` 改为从逻辑今天做日历加法：

```qml
        // 默认 30 天后必须从逻辑今天起算：凌晨日界点前不能比全 app 多算一天。
        var defaultDate = new Date(root.logicalToday())
        defaultDate.setDate(defaultDate.getDate() + 30)
        dateField.text = dateToInput(defaultDate)
```

`tests/qml/tst_countdown_ui.qml`：

1）TestCase 属性区加固定时钟，并提供 appSettings mock：

```qml
    property var fakeNow: new Date(2026, 6, 8, 3, 59)

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }
```

2）CountdownDialog 实例增加固定 provider（函数本身不替换，只修改 `fakeNow`）：

```qml
        logicalNowProvider: function() { return testCase.fakeNow }
```

3）`init()` 中复位：

```qml
        testCase.fakeNow = new Date(2026, 6, 8, 3, 59)
```

4）新增用例：

```qml
    function test_dialogDefaultDateUsesLogicalToday() {
        // 7月8日 03:59、h=4 → 逻辑今天 7月7日；默认 30 天后应是 8月6日。
        compare(countdownDialog.dateToInput(null), "2026-07-07")
        countdownDialog.openForAdd()
        var dateField = findChild(countdownDialog, "countdownDateField")
        verify(dateField)
        compare(dateField.text, "2026-08-06")

        // 跨过 4 点后逻辑今天变 7月8日，默认值同步变为 8月7日。
        countdownDialog.close()
        testCase.fakeNow = new Date(2026, 6, 8, 4, 0)
        countdownDialog.openForAdd()
        compare(dateField.text, "2026-08-07")
    }
```

- [ ] **Step 6: 回归 ×2 + lint**

Run（各 ×2）:
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_add_task_dialog.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_edit_task_dialog.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_phase3_export_ui.qml`
`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_countdown_ui.qml`
Expected: 全绿 ×2（白天运行逻辑今天=物理今天，既有断言不变；若有用例把"今天"写死为 `new Date()` 对比而失败，把该断言改为经 `LogicalDay.todayDate(4, new Date())` 计算——语义即"与组件同口径"）。
Run: `for f in qml/views/TodayTaskView.qml qml/components/AddTaskDialog.qml qml/components/EditTaskDialog.qml qml/components/ExportDialog.qml qml/components/CountdownDialog.qml; do /Users/zerionlito/Qt/6.9.0/macos/bin/qmllint $f; done`
Expected: 不新增警告。

- [ ] **Step 7: 提交**

```bash
git add qml/views/TodayTaskView.qml qml/components/AddTaskDialog.qml qml/components/EditTaskDialog.qml qml/components/ExportDialog.qml qml/components/CountdownDialog.qml tests/qml/tst_countdown_ui.qml
git commit -m "QML 今日入口统一逻辑日（任务编辑导出与倒计时默认日期）"
```

---

### Task 4: WeekPlanView 落 logicalToday + 订阅失效

**Files:**
- Modify: `qml/views/WeekPlanView.qml`
- Test: `tests/qml/tst_week_logical_day.qml`（新建）

**Interfaces:**
- Consumes: `LogicalDay.todayDate`、上下文属性 `logicalDayService`。
- Produces: `property date logicalToday`（命令式状态）、`property var logicalNowProvider`、`computeLogicalToday()`；`isTodayIndex`/`isPastIndex`/weekStart 初始/"本周"按钮全部基于 logicalToday；`onChanged` 六步顺序（跟随/保留）。

- [ ] **Step 1: 写失败测试（新建 `tests/qml/tst_week_logical_day.qml`）**

```qml
import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "WeekLogicalDay"
    when: windowShown
    width: 1000
    height: 700

    // 固定 provider 函数读可变 fakeNow：换 provider 函数本身会提前触发属性变化，
    // 必须只改 fakeNow、再发 changed，让生产 onChanged 自己算出新 logicalToday。
    property var fakeNow: new Date(2026, 6, 13, 3, 59)

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    QtObject {
        id: taskManager

        signal tasksChanged()

        function getWeekTasks(weekStartIso) { return [] }
    }

    WeekPlanView {
        id: view

        width: 1000
        height: 700
        logicalNowProvider: function() { return testCase.fakeNow }
    }

    function isoDate(value) {
        return Qt.formatDate(value, "yyyy-MM-dd")
    }

    function init() {
        // 基线：2026-07-13(周一) 凌晨 3:59 → 逻辑今天 7月12日(周日)，逻辑本周起点 7月6日。
        testCase.fakeNow = new Date(2026, 6, 13, 3, 59)
        view.logicalToday = view.computeLogicalToday()
        view.weekStart = view.mondayOf(view.logicalToday)
    }

    function test_initialStateUsesLogicalToday() {
        compare(isoDate(view.logicalToday), "2026-07-12")
        compare(isoDate(view.weekStart), "2026-07-06")
        // 周日（索引 6）是逻辑今天；周六（索引 5）是过去；今天不算过去。
        verify(view.isTodayIndex(6))
        verify(!view.isTodayIndex(0))
        verify(view.isPastIndex(5))
        verify(!view.isPastIndex(6))
    }

    function test_boundaryCrossFollowsWhenOnCurrentWeek() {
        // 停在逻辑本周，跨 4 点（周日→周一即跨周）：weekStart 跟到新逻辑周。
        testCase.fakeNow = new Date(2026, 6, 13, 4, 0)
        logicalDayService.changed()

        compare(isoDate(view.logicalToday), "2026-07-13")
        compare(isoDate(view.weekStart), "2026-07-13")
        verify(view.isTodayIndex(0))
    }

    function test_boundaryCrossKeepsHistoricalWeek() {
        // 先翻到历史周再跨日：保留浏览位置，不许把用户拉走。
        view.weekStart = new Date(2026, 5, 29)
        testCase.fakeNow = new Date(2026, 6, 13, 4, 0)
        logicalDayService.changed()

        compare(isoDate(view.logicalToday), "2026-07-13")
        compare(isoDate(view.weekStart), "2026-06-29")
    }

    function test_thisWeekButtonUsesLogicalToday() {
        // 真实点击按钮：验证的是 onClicked 用 logicalToday，不是复述实现。
        view.weekStart = new Date(2026, 5, 29)
        var button = findChild(view, "weekThisWeekButton")
        verify(button)
        mouseClick(button)
        compare(isoDate(view.weekStart), "2026-07-06")
    }
}
```

- [ ] **Step 2: 确认失败（RED）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_week_logical_day.qml`
Expected: FAIL（`logicalNowProvider`/`logicalToday`/`computeLogicalToday` 不存在）。

- [ ] **Step 3: 实现**

`qml/views/WeekPlanView.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）`property date weekStart: mondayOf(new Date())`（13 行）之后加（weekStart 初始表达式保留——它是一次性求值的兜底，`Component.onCompleted` 会立即用逻辑值覆盖；**不得**把 weekStart 绑定到 logicalToday，否则 logicalToday 赋新值时先联动、onChanged 再判断旧位置，顺序不可靠）：

```qml
    // 逻辑今天：命令式状态，不能写成绑定——绑定依赖 dayStartHour/provider，
    // 会在 changed 信号到达前被提前重算，onChanged 里保存的 prev 就不再是旧值。
    property date logicalToday
    // 仅测试注入的时间源；生产为 null → new Date()。
    property var logicalNowProvider: null
```

3）`Component.onCompleted: refresh()`（24 行）改为：

```qml
    Component.onCompleted: {
        logicalToday = computeLogicalToday()
        weekStart = mondayOf(logicalToday)
        refresh()
    }
```

4）`mondayOf` 函数前加：

```qml
    function computeLogicalToday() {
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(h, now)
    }
```

5）`isTodayIndex`（约 96-103 行）整函数替换：

```qml
    function isTodayIndex(index) {
        // 与逻辑今天比：凌晨 0-4 点周计划页和今日页必须认同一天，否则两页自相矛盾。
        var d = root.dayDate(index)
        var today = root.logicalToday
        return d.getFullYear() === today.getFullYear()
                && d.getMonth() === today.getMonth()
                && d.getDate() === today.getDate()
    }
```

6）`isPastIndex`（约 105-111 行）整函数替换：

```qml
    function isPastIndex(index) {
        var d = root.dayDate(index)
        d.setHours(0, 0, 0, 0)
        var today = new Date(root.logicalToday)
        today.setHours(0, 0, 0, 0)
        return d.getTime() < today.getTime()
    }
```

7）"本周"按钮（id `thisWeekButton`，约 269-272 行）：在其 `text` 属性行旁加测试寻址用 objectName，并改 onClicked：

```qml
                objectName: "weekThisWeekButton"
```

```qml
                onClicked: {
                    root.weekStart = root.mondayOf(root.logicalToday)
                    root.refresh()
                }
```

8）既有 categoryManagerRef 的 Connections 之后加订阅（六步固定顺序）：

```qml
    Connections {
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            // 顺序契约：①存旧值 ②赋新值前判断"原本是否停在逻辑本周" ③算新值
            // ④赋值 ⑤按②的结果决定跟随/保留 ⑥刷新。乱序会用新值判断旧位置。
            var prev = root.logicalToday
            var wasFollowingCurrentWeek = root.weekStart.getTime() === root.mondayOf(prev).getTime()
            var next = root.computeLogicalToday()
            root.logicalToday = next
            if (wasFollowingCurrentWeek) {
                root.weekStart = root.mondayOf(next)
            }
            root.refresh()
        }
    }
```

- [ ] **Step 4: 跑测试（GREEN）×2 + 既有回归 + lint**

Run（×2）: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_week_logical_day.qml`
Expected: 全绿 ×2。
Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml`
Expected: 全绿（该文件有既有偶发，重跑区分；WeekPlanView 既有断言基于当天白天运行时逻辑=物理，不变）。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/WeekPlanView.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/views/WeekPlanView.qml tests/qml/tst_week_logical_day.qml
git commit -m "周计划落 logicalToday 命令式状态并订阅失效（当前周跟随/历史周保留）"
```

---

### Task 5: MonthGoalView 落 logicalToday + 全"今天"入口 + 订阅失效

**Files:**
- Modify: `qml/views/MonthGoalView.qml`
- Test: `tests/qml/tst_month_logical_day.qml`（新建）

**Interfaces:**
- Consumes: 同 Task 4。
- Produces: 初始定位/"本月"按钮/`todayCell` 高亮全部基于 `logicalToday`；`onChanged`"选中恰为旧逻辑今天才跟随，否则保留位置"。

- [ ] **Step 1: 写失败测试（新建 `tests/qml/tst_month_logical_day.qml`）**

（不 mock `focusHistoryService`：MonthGoalView 缺服务时走优雅降级路径、正好隔离日期逻辑。）

```qml
import QtQuick
import QtTest
import "../../qml/views"

TestCase {
    id: testCase
    name: "MonthLogicalDay"
    when: windowShown
    width: 1000
    height: 800

    property var fakeNow: new Date(2026, 6, 8, 3, 59)

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: logicalDayService

        signal changed()
    }

    MonthGoalView {
        id: view

        width: 1000
        height: 800
        logicalNowProvider: function() { return testCase.fakeNow }
    }

    function init() {
        // 基线：2026-07-08 凌晨 3:59 → 逻辑今天 7月7日。
        testCase.fakeNow = new Date(2026, 6, 8, 3, 59)
        view.logicalToday = view.computeLogicalToday()
        view.setMonth(view.logicalToday.getFullYear(), view.logicalToday.getMonth() + 1,
                      view.logicalToday.getDate())
        wait(20)
    }

    function test_initialSelectionAndHighlightUseLogicalToday() {
        compare(view.currentYear, 2026)
        compare(view.currentMonth, 7)
        compare(view.selectedDay, 7)

        // 高亮必须与选中一致——这正是"初始选中昨天、高亮却是今天"矛盾的回归锁。
        var cell7 = findChild(view, "monthDayCell-7")
        var cell8 = findChild(view, "monthDayCell-8")
        verify(cell7)
        verify(cell8)
        verify(cell7.todayCell)
        verify(!cell8.todayCell)
    }

    function test_boundaryCrossFollowsWhenSelectedIsOldToday() {
        // 选中恰是旧逻辑今天 → 跨 4 点后跟到新逻辑今天，高亮同步移动（响应式重算）。
        testCase.fakeNow = new Date(2026, 6, 8, 4, 0)
        logicalDayService.changed()

        compare(view.selectedDay, 8)
        verify(findChild(view, "monthDayCell-8").todayCell)
        verify(!findChild(view, "monthDayCell-7").todayCell)
    }

    function test_boundaryCrossKeepsUserPickedDay() {
        // 用户在当前月查看 5 号（非旧逻辑今天）：跨日不许把 TA 拽到 8 号。
        view.setMonth(2026, 7, 5)
        testCase.fakeNow = new Date(2026, 6, 8, 4, 0)
        logicalDayService.changed()

        compare(view.currentMonth, 7)
        compare(view.selectedDay, 5)
        // 但"今天"高亮仍要随 logicalToday 走到 8 号。
        verify(findChild(view, "monthDayCell-8").todayCell)
    }
}
```

- [ ] **Step 2: 确认失败（RED）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_month_logical_day.qml`
Expected: FAIL（`logicalNowProvider`/`computeLogicalToday` 不存在）。

- [ ] **Step 3: 实现**

`qml/views/MonthGoalView.qml`：

1）import 区加：

```qml
import "../LogicalDay.js" as LogicalDay
```

2）属性区（`property int selectedDay: new Date().getDate()` 之后）加（三个初始表达式保留作一次性兜底，onCompleted 立即覆盖；**不得**改成绑定到 logicalToday）：

```qml
    // 逻辑今天：命令式状态，不能写成绑定（changed 到达前会被 dayStartHour/provider
    // 变化提前重算，onChanged 里的 prev 失真）。
    property date logicalToday
    // 仅测试注入的时间源；生产为 null → new Date()。
    property var logicalNowProvider: null
```

3）`Component.onCompleted: refresh()` 改为：

```qml
    Component.onCompleted: {
        logicalToday = computeLogicalToday()
        currentYear = logicalToday.getFullYear()
        currentMonth = logicalToday.getMonth() + 1
        selectedDay = logicalToday.getDate()
        refresh()
    }
```

4）`hasFocusHistoryService` 函数前加：

```qml
    function computeLogicalToday() {
        var now = root.logicalNowProvider ? root.logicalNowProvider() : new Date()
        // qmllint disable unqualified
        var h = (typeof appSettings !== "undefined" && appSettings) ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(h, now)
    }
```

5）"本月"按钮 onClicked（约 300-303 行）改为：

```qml
                    onClicked: {
                        var today = root.logicalToday;
                        root.setMonth(today.getFullYear(), today.getMonth() + 1, today.getDate());
                    }
```

6）`todayCell`（约 494-497 行）改为（绑定依赖 `root.logicalToday`，跨日赋新值即自动重算）：

```qml
                                    property bool todayCell: {
                                        var today = root.logicalToday;
                                        return dayNumber > 0 && root.currentYear === today.getFullYear() && root.currentMonth === today.getMonth() + 1 && dayNumber === today.getDate();
                                    }
```

7）既有 focusTimer 的 Connections 之后加订阅：

```qml
    Connections {
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            // 只有"选中的就是旧逻辑今天"才跟随——只比当前月不够：
            // 用户在当前月看 7 号，跨日后不该被强制跳到 8 号。
            var prev = root.logicalToday
            var wasFollowingCurrentDay = root.selectedDay === prev.getDate()
                    && root.currentMonth === prev.getMonth() + 1
                    && root.currentYear === prev.getFullYear()
            var next = root.computeLogicalToday()
            root.logicalToday = next
            if (wasFollowingCurrentDay) {
                root.setMonth(next.getFullYear(), next.getMonth() + 1, next.getDate())
            } else {
                root.refresh()
            }
        }
    }
```

- [ ] **Step 4: 跑测试（GREEN）×2 + lint**

Run（×2）: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_month_logical_day.qml`
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/MonthGoalView.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/views/MonthGoalView.qml tests/qml/tst_month_logical_day.qml
git commit -m "月历落 logicalToday（初始/本月按钮/今天高亮同口径）并订阅失效（选中旧今天才跟随）"
```

---

### Task 6: TodayTaskView 订阅失效

**Files:**
- Modify: `qml/views/TodayTaskView.qml`
- Test: `tests/qml/tst_today_rollover.qml`

**Interfaces:**
- Consumes: 上下文属性 `logicalDayService`。
- Produces: 跨日界/改设置后今日页自动 `refresh()`（例行已由 main.cpp 直连先行落库——计划一 Task 6）。

- [ ] **Step 1: 写失败测试**

`tests/qml/tst_today_rollover.qml`：

1）`taskManager` mock 里 `property int moveCalls: 0` 后加计数：

```qml
        property int todayCalls: 0
```

`getTodayTasks()` 函数体改为：

```qml
        function getTodayTasks() {
            todayCalls += 1
            return todayTasksData
        }
```

2）顶层 mock 区（taskManager 对象之后）加：

```qml
    QtObject {
        id: logicalDayService

        signal changed()
    }
```

3）文件末尾加测试：

```qml
    function test_logicalDayChangedTriggersRefresh() {
        var before = taskManager.todayCalls
        logicalDayService.changed()
        verify(taskManager.todayCalls > before)
    }
```

- [ ] **Step 2: 确认失败（RED）**

Run: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml`
Expected: 新用例 FAIL（无订阅，todayCalls 不变），其余全绿。

- [ ] **Step 3: 实现**

`qml/views/TodayTaskView.qml`，既有 routineManager 的 Connections（约 72-79 行）之后加：

```qml
    Connections {
        // 逻辑日失效 → 重查今日任务与结转横幅。例行补齐由 main.cpp 的直连先行完成，
        // 此处刷新时新逻辑日的例行任务已落库。
        // qmllint disable unqualified
        target: typeof logicalDayService !== "undefined" ? logicalDayService : null
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onChanged() {
            root.refresh()
        }
    }
```

- [ ] **Step 4: 跑测试（GREEN）×2 + lint**

Run（×2）: `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml`
Expected: 全绿 ×2。
Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/views/TodayTaskView.qml`
Expected: 不新增警告。

- [ ] **Step 5: 提交**

```bash
git add qml/views/TodayTaskView.qml tests/qml/tst_today_rollover.qml
git commit -m "今日页订阅逻辑日失效（跨日界/改设置自动重查任务与结转）"
```

---

### Task 7: 全量无头回归 + 收官汇报

**Files:** 无新改动（验证任务）。

- [ ] **Step 1: 全量回归 ×2**

Run（×2）: `cmake --build build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --test-dir build --output-on-failure`
Expected: 全部通过（既有 offscreen 偶发按基线重跑区分）。

- [ ] **Step 2: 残留核对**

Run: `grep -rn "QDate::currentDate" src/services/ src/models/`
Expected: 仅剩与"今天"语义无关的用途（如时间戳生成）；`TaskManager/RoutineManager/StatisticsService/CountdownService/CountdownGoal` 中不应再有"今天"含义的 currentDate。
Run: `grep -rn "new Date()\|Date.now()" qml/views/TodayTaskView.qml qml/views/WeekPlanView.qml qml/views/MonthGoalView.qml qml/components/AddTaskDialog.qml qml/components/EditTaskDialog.qml qml/components/ExportDialog.qml qml/components/CountdownDialog.qml | grep -v "logicalNowProvider\|computeLogicalToday\|LogicalDay.today\|logicalToday()"`
Expected: 输出里不应有"今天"语义的裸 `new Date()`（provider 兜底与非日期用途除外，逐条人工确认）。

- [ ] **Step 3: 收官汇报**

汇报：全 app"今天"统一逻辑日（任务/结转/例行/倒计时双路径与新增目标默认日期/周计划/月历/统计/导出/对话框）、跨设置与跨日界自动刷新（Today/Week/Month/Statistics/Countdown 全订阅，Week/Month 带"当前期跟随、历史期保留"）、测试全绿 ×2。等待用户人工验收（改设置步进器 → 各页即时刷新；可把日界点临时调到当前小时+1 观察跨界行为）。**不自行合并回 main。**
