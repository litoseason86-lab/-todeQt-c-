# 月度专注记录功能实施计划 - Part 2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将FocusHistoryService集成到QML上下文，并重构MonthGoalView移除任务相关逻辑

**Architecture:** 通过CMakeLists.txt和main.cpp将Service注册到QML，然后逐步移除MonthGoalView中的任务管理功能，保留日历结构

**Tech Stack:** CMake, Qt 6.8 QML Context, QML

---

## Task 5: 注册服务到QML

**Files:**
- Modify: `CMakeLists.txt`
- Modify: `src/main.cpp`

- [ ] **Step 1: 在CMakeLists.txt中添加新文件 - 第一个模块**

找到现有的Service文件列表（应该在 `src/services/StatisticsService.cpp` 附近），在该位置添加：

```cmake
    src/services/FocusHistoryService.h
    src/services/FocusHistoryService.cpp
```

- [ ] **Step 2: 验证CMakeLists.txt修改**

```bash
grep -A 2 -B 2 "FocusHistoryService" CMakeLists.txt
```

预期输出：显示FocusHistoryService的.h和.cpp文件在构建列表中

- [ ] **Step 3: 重新配置CMake**

```bash
cd /Users/zerionlito/code/番茄todo
cmake -B build
```

预期输出：配置成功，无错误

- [ ] **Step 4: 验证编译**

```bash
cmake --build build
```

预期输出：编译成功，生成可执行文件

- [ ] **Step 5: 提交CMakeLists.txt修改**

```bash
git add CMakeLists.txt
git commit -m "build: add FocusHistoryService to CMakeLists.txt

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: 在main.cpp中导入FocusHistoryService - 第二个模块**

在 `src/main.cpp` 文件顶部的include区域，找到其他Service的导入（如 `#include "services/StatisticsService.h"`），在附近添加：

```cpp
#include "services/FocusHistoryService.h"
```

- [ ] **Step 7: 在main.cpp中注册到QML上下文**

在 `main()` 函数中，找到其他service注册的位置（如 `engine.rootContext()->setContextProperty`），在该位置附近添加：

```cpp
    engine.rootContext()->setContextProperty("focusHistoryService", FocusHistoryService::instance());
```

- [ ] **Step 8: 验证main.cpp修改**

```bash
grep -n "FocusHistoryService" src/main.cpp
```

预期输出：显示两行，一行是include，一行是setContextProperty

- [ ] **Step 9: 编译验证**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 10: 运行应用验证Service可用**

```bash
./build/TomatoTodo
```

手动测试：打开应用，在QML Console中应该可以访问 `focusHistoryService` 对象（不会报错）

- [ ] **Step 11: 提交main.cpp修改**

```bash
git add src/main.cpp
git commit -m "feat: register FocusHistoryService to QML context

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: 重构MonthGoalView - 移除旧逻辑

**Files:**
- Modify: `qml/views/MonthGoalView.qml`

- [ ] **Step 1: 备份当前文件**

```bash
cp qml/views/MonthGoalView.qml qml/views/MonthGoalView.qml.backup
```

- [ ] **Step 2: 记录当前文件结构**

```bash
grep -n "^import\|^Item\|^Rectangle\|id:" qml/views/MonthGoalView.qml | head -20
```

这帮助我们了解当前结构

- [ ] **Step 3: 移除第一个功能模块 - 3个统计卡片**

找到并删除3个StatCard组件（大约在第307-330行附近）：

从：
```qml
        // Statistics Cards
        Row {
            id: statsRow
            spacing: 20
            
            StatCard {
                title: "本月任务"
                value: monthTasks.length
                // ...
            }
            
            StatCard {
                title: "已完成"
                value: completedCount
                // ...
            }
            
            StatCard {
                title: "完成率"
                value: completionRate + "%"
                // ...
            }
        }
```

改为：
```qml
        // Statistics Cards removed - focus history doesn't need task stats
```

- [ ] **Step 4: 移除第二个功能模块 - 任务相关属性**

找到并删除任务相关的属性定义（大约在顶部property区域）：

删除：
```qml
    property var monthTasks: []
    property int completedCount: 0
    property int completionRate: 0
```

这些属性不再需要

- [ ] **Step 5: 移除第三个功能模块 - 任务详情面板**

找到任务详情面板部分（大约在第485-601行），从：

```qml
        // Task Detail Panel
        Rectangle {
            id: taskDetailPanel
            // ... 大量任务相关代码
        }
```

完全删除这个Rectangle块

- [ ] **Step 6: 移除第四个功能模块 - 任务相关函数**

找到并删除以下函数：
- `refresh()` 中与任务相关的逻辑
- `updateMonthTasks()` 函数
- `calculateStats()` 函数
- 任何其他任务相关的函数

保留：
- 日历相关函数
- 月份切换逻辑
- 日期选择逻辑

- [ ] **Step 7: 更新页面标题**

找到页面标题部分，将 "月度目标" 改为 "专注历史"：

从：
```qml
    Text {
        text: "月度目标"
        font.pixelSize: 24
        font.weight: Font.Bold
        color: "#5d4e37"
    }
```

改为：
```qml
    Text {
        text: "专注历史"
        font.pixelSize: 24
        font.weight: Font.Bold
        color: "#5d4e37"
    }
```

- [ ] **Step 8: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功，QML没有语法错误

- [ ] **Step 9: 运行应用验证基本结构**

```bash
./build/TomatoTodo
```

手动测试：
- 点击侧边栏的"月度目标"入口
- 页面应该显示，但没有统计卡片和任务列表
- 日历应该正常显示
- 月份切换按钮应该正常工作

- [ ] **Step 10: 提交移除旧逻辑的修改**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "refactor: remove task-related logic from MonthGoalView

- Remove 3 statistics cards
- Remove task detail panel
- Remove task-related properties and functions
- Update page title to '专注历史'
- Keep calendar structure and month navigation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: 添加专注记录数据绑定

**Files:**
- Modify: `qml/views/MonthGoalView.qml`

- [ ] **Step 1: 添加专注记录相关属性 - 第一个模块**

在MonthGoalView的顶部property区域，添加：

```qml
    // 专注记录数据
    property var monthSessions: []           // 本月所有专注记录
    property var selectedDaySessions: []     // 当前选中日期的专注记录
    property var dailyTotals: ({})           // 每天的总时长（秒），格式：{"2026-06-10": 13320, ...}
```

- [ ] **Step 2: 添加刷新数据的函数 - 第二个模块**

在MonthGoalView中添加新的refresh函数：

```qml
    function refresh() {
        // 获取当前月份的所有专注记录
        monthSessions = focusHistoryService.getMonthSessions(currentYear, currentMonth);
        
        // 计算每天的总时长
        calculateDailyTotals();
        
        // 更新选中日期的记录
        updateSelectedDaySessions();
    }
```

- [ ] **Step 3: 实现calculateDailyTotals函数 - 第三个模块**

添加计算每日总时长的函数：

```qml
    function calculateDailyTotals() {
        var totals = {};
        
        for (var i = 0; i < monthSessions.length; i++) {
            var session = monthSessions[i];
            var date = session.date;  // "2026-06-10"
            
            if (!totals[date]) {
                totals[date] = 0;
            }
            
            totals[date] += session.durationSeconds;
        }
        
        dailyTotals = totals;
    }
```

- [ ] **Step 4: 实现updateSelectedDaySessions函数 - 第四个模块**

添加更新选中日期记录的函数：

```qml
    function updateSelectedDaySessions() {
        var selectedDateStr = Qt.formatDate(
            new Date(currentYear, currentMonth - 1, selectedDay),
            "yyyy-MM-dd"
        );
        
        var filtered = [];
        for (var i = 0; i < monthSessions.length; i++) {
            if (monthSessions[i].date === selectedDateStr) {
                filtered.push(monthSessions[i]);
            }
        }
        
        selectedDaySessions = filtered;
    }
```

- [ ] **Step 5: 在Component.onCompleted中调用refresh**

找到MonthGoalView的Component.onCompleted，确保调用refresh：

```qml
    Component.onCompleted: {
        refresh();
    }
```

- [ ] **Step 6: 在月份切换时调用refresh**

找到月份切换按钮的onClicked处理，添加refresh调用：

在"上月"按钮的onClicked中：
```qml
onClicked: {
    if (currentMonth === 1) {
        currentMonth = 12;
        currentYear--;
    } else {
        currentMonth--;
    }
    selectedDay = 1;  // 重置选中日期
    refresh();
}
```

在"下月"按钮的onClicked中：
```qml
onClicked: {
    if (currentMonth === 12) {
        currentMonth = 1;
        currentYear++;
    } else {
        currentMonth++;
    }
    selectedDay = 1;  // 重置选中日期
    refresh();
}
```

在"本月"按钮的onClicked中：
```qml
onClicked: {
    var today = new Date();
    currentYear = today.getFullYear();
    currentMonth = today.getMonth() + 1;
    selectedDay = today.getDate();
    refresh();
}
```

- [ ] **Step 7: 在日期选择时更新selectedDaySessions**

找到日历格子的点击处理（MouseArea的onClicked），添加：

```qml
onClicked: {
    selectedDay = dayNumber;
    updateSelectedDaySessions();
}
```

- [ ] **Step 8: 验证编译**

```bash
cd /Users/zerionlito/code/番茄todo
cmake --build build
```

预期输出：编译成功

- [ ] **Step 9: 运行应用验证数据绑定**

```bash
./build/TomatoTodo
```

手动测试：
- 打开专注历史页面
- 在QML Console中输入 `console.log(monthSessions.length)` 查看是否有数据
- 切换月份，观察控制台是否有日志
- 点击不同日期，观察selectedDaySessions是否变化

- [ ] **Step 10: 添加调试日志验证数据流**

在refresh()函数开头添加临时日志：

```qml
    function refresh() {
        console.log("Refreshing focus history for", currentYear, currentMonth);
        monthSessions = focusHistoryService.getMonthSessions(currentYear, currentMonth);
        console.log("Loaded", monthSessions.length, "sessions");
        
        calculateDailyTotals();
        console.log("Daily totals:", JSON.stringify(dailyTotals));
        
        updateSelectedDaySessions();
    }
```

- [ ] **Step 11: 提交数据绑定代码**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "feat: add focus session data binding to MonthGoalView

- Add monthSessions, selectedDaySessions, dailyTotals properties
- Implement refresh(), calculateDailyTotals(), updateSelectedDaySessions()
- Connect data refresh to month navigation and date selection
- Add debug logging for data flow verification

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 12: 最终检查 - 验证数据绑定完整性**

```bash
grep -n "property var.*Sessions\|function refresh\|function calculate\|function update" qml/views/MonthGoalView.qml
```

预期输出：显示所有新添加的属性和函数定义

---

## Part 2 完成检查清单

在继续Part 3之前，确认以下内容：

- [ ] FocusHistoryService已添加到CMakeLists.txt
- [ ] FocusHistoryService已在main.cpp中注册到QML上下文
- [ ] 应用可以成功编译和运行
- [ ] MonthGoalView中的任务相关逻辑已完全移除
- [ ] 页面标题已更改为"专注历史"
- [ ] 日历结构和月份导航功能保持正常
- [ ] monthSessions属性可以从focusHistoryService获取数据
- [ ] dailyTotals正确计算每天的总时长
- [ ] selectedDaySessions根据选中日期正确更新
- [ ] 所有修改已提交到git

**下一步：** 继续 Part 3，改造日历显示逻辑和实现时间轴组件
