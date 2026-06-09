# Phase 2: Week Plan, Statistics, and Month View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement week plan view, complete statistics dashboard with charts, and month goal view for the Pomodoro Todo app.

**Architecture:** Extend existing TaskManager service with week/month query methods, create StatisticsView with chart components (bar/pie), and implement WeekPlanView and MonthGoalView using existing architecture patterns.

**Tech Stack:** Qt 6, Qt Quick/QML, Qt Charts, C++17, SQLite

---

## File Structure Overview

This phase will add the following files:

```
番茄todo/
├── src/services/
│   ├── TaskManager.h/cpp          # MODIFY: Add getWeekTasks(), getMonthTasks()
│   └── StatisticsService.h/cpp    # MODIFY: Add getCategoryStats()
├── qml/
│   ├── MainWindow.qml              # MODIFY: Add new views to StackLayout
│   ├── views/
│   │   ├── WeekPlanView.qml        # CREATE: Week tasks view
│   │   ├── StatisticsView.qml      # CREATE: Stats dashboard
│   │   └── MonthGoalView.qml       # CREATE: Month calendar view
│   └── components/
│       ├── StatCard.qml            # CREATE: Statistics card component
│       ├── ChartBar.qml            # CREATE: Bar chart for week trend
│       └── ChartPie.qml            # CREATE: Pie chart for category distribution
└── CMakeLists.txt                  # MODIFY: Add Qt Charts dependency
```

---

## Task 1: Add Qt Charts Dependency

**Files:**
- Modify: `CMakeLists.txt`

- [ ] **Step 1: Update CMakeLists.txt to include Qt Charts**

Find and update the Qt package line:

```cmake
find_package(Qt6 REQUIRED COMPONENTS Core Quick Sql Charts)
```

And update the target_link_libraries:

```cmake
target_link_libraries(PomodoroTodo PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::Sql
    Qt6::Charts
)
```

- [ ] **Step 2: Reconfigure CMake**

```bash
cd build
cmake ..
```

Expected: CMake configures successfully with Qt Charts

- [ ] **Step 3: Commit**

```bash
git add CMakeLists.txt
git commit -m "build: add Qt Charts dependency for statistics view"
```

---

## Task 2: Extend TaskManager with Week and Month Queries

**Files:**
- Modify: `src/services/TaskManager.h`
- Modify: `src/services/TaskManager.cpp`

- [ ] **Step 1: Add week/month query methods to header**

Add to `src/services/TaskManager.h` in the public section:

```cpp
Q_INVOKABLE QVariantList getWeekTasks(const QDate& startDate);
Q_INVOKABLE QVariantList getMonthTasks(int year, int month);
```

- [ ] **Step 2: Implement getWeekTasks**

Add to `src/services/TaskManager.cpp`:

```cpp
QVariantList TaskManager::getWeekTasks(const QDate& startDate)
{
    QVariantList tasks;
    QDate endDate = startDate.addDays(6);
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT id, title, category, date, completed FROM tasks WHERE date >= ? AND date <= ? ORDER BY date, created_at");
    query.addBindValue(startDate);
    query.addBindValue(endDate);
    
    if (!query.exec()) {
        qWarning() << "Failed to get week tasks:" << query.lastError().text();
        return tasks;
    }
    
    while (query.next()) {
        QVariantMap task;
        task["id"] = query.value(0).toInt();
        task["title"] = query.value(1).toString();
        task["category"] = query.value(2).toString();
        task["date"] = query.value(3).toDate();
        task["completed"] = query.value(4).toBool();
        tasks.append(task);
    }
    
    return tasks;
}
```

- [ ] **Step 3: Implement getMonthTasks**

Add to `src/services/TaskManager.cpp`:

```cpp
QVariantList TaskManager::getMonthTasks(int year, int month)
{
    QVariantList tasks;
    QDate startDate(year, month, 1);
    QDate endDate = startDate.addMonths(1).addDays(-1);
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT id, title, category, date, completed FROM tasks WHERE date >= ? AND date <= ? ORDER BY date, created_at");
    query.addBindValue(startDate);
    query.addBindValue(endDate);
    
    if (!query.exec()) {
        qWarning() << "Failed to get month tasks:" << query.lastError().text();
        return tasks;
    }
    
    while (query.next()) {
        QVariantMap task;
        task["id"] = query.value(0).toInt();
        task["title"] = query.value(1).toString();
        task["category"] = query.value(2).toString();
        task["date"] = query.value(3).toDate();
        task["completed"] = query.value(4).toBool();
        tasks.append(task);
    }
    
    return tasks;
}
```

- [ ] **Step 4: Build and test**

```bash
cd build
cmake --build .
```

Expected: Builds successfully

- [ ] **Step 5: Commit**

```bash
git add src/services/TaskManager.h src/services/TaskManager.cpp
git commit -m "feat: add week and month task query methods to TaskManager"
```

---

## Task 3: Extend StatisticsService with Category Stats

**Files:**
- Modify: `src/services/StatisticsService.h`
- Modify: `src/services/StatisticsService.cpp`

- [ ] **Step 1: Add getCategoryStats method to header**

Add to `src/services/StatisticsService.h` in the public section:

```cpp
Q_INVOKABLE QVariantMap getCategoryStats(const QDate& startDate, const QDate& endDate);
```

- [ ] **Step 2: Implement getCategoryStats**

Add to `src/services/StatisticsService.cpp`:

```cpp
QVariantMap StatisticsService::getCategoryStats(const QDate& startDate, const QDate& endDate)
{
    QVariantMap result;
    QVariantList categories;
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(
        "SELECT t.category, SUM(f.duration) as total_duration "
        "FROM focus_sessions f "
        "JOIN tasks t ON f.task_id = t.id "
        "WHERE DATE(f.start_time) >= ? AND DATE(f.start_time) <= ? "
        "AND t.category IS NOT NULL AND t.category != '' "
        "GROUP BY t.category "
        "ORDER BY total_duration DESC"
    );
    query.addBindValue(startDate);
    query.addBindValue(endDate);
    
    if (!query.exec()) {
        qWarning() << "Failed to get category stats:" << query.lastError().text();
        result["categories"] = categories;
        result["totalDuration"] = 0;
        return result;
    }
    
    int totalDuration = 0;
    while (query.next()) {
        QVariantMap category;
        QString name = query.value(0).toString();
        int duration = query.value(1).toInt();
        
        category["name"] = name;
        category["duration"] = duration;
        categories.append(category);
        totalDuration += duration;
    }
    
    // Calculate percentages
    for (int i = 0; i < categories.size(); ++i) {
        QVariantMap cat = categories[i].toMap();
        int duration = cat["duration"].toInt();
        double percentage = totalDuration > 0 ? (duration * 100.0 / totalDuration) : 0.0;
        cat["percentage"] = percentage;
        categories[i] = cat;
    }
    
    result["categories"] = categories;
    result["totalDuration"] = totalDuration;
    return result;
}
```

- [ ] **Step 3: Build and test**

```bash
cd build
cmake --build .
```

Expected: Builds successfully

- [ ] **Step 4: Commit**

```bash
git add src/services/StatisticsService.h src/services/StatisticsService.cpp
git commit -m "feat: add category statistics calculation to StatisticsService"
```

---

## Task 4: Create StatCard Component

**Files:**
- Create: `qml/components/StatCard.qml`

- [ ] **Step 1: Create StatCard.qml**

Create file with this content:

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0

Rectangle {
    id: root
    
    property string title: ""
    property string value: ""
    property string unit: ""
    property string subtitle: ""
    
    width: 200
    height: 120
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1
    
    Column {
        anchors.centerIn: parent
        spacing: 8
        
        Text {
            text: root.title
            font.pixelSize: 14
            color: "#8b7355"
            anchors.horizontalCenter: parent.horizontalCenter
        }
        
        Row {
            spacing: 4
            anchors.horizontalCenter: parent.horizontalCenter
            
            Text {
                text: root.value
                font.pixelSize: 36
                font.bold: true
                color: "#5d4e37"
            }
            
            Text {
                text: root.unit
                font.pixelSize: 16
                color: "#8b7355"
                anchors.baseline: parent.children[0].baseline
            }
        }
        
        Text {
            text: root.subtitle
            font.pixelSize: 12
            color: "#8b7355"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.subtitle !== ""
        }
    }
}
```

- [ ] **Step 2: Test the component**

Add a test instance in `qml/MainWindow.qml` temporarily (remove after verification):

```qml
StatCard {
    title: "今日专注"
    value: "2.5"
    unit: "小时"
    subtitle: "已完成 5/8 任务"
}
```

- [ ] **Step 3: Build and run**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: StatCard displays correctly with warm paper theme

- [ ] **Step 4: Remove test code and commit**

Remove the test StatCard from MainWindow.qml, then:

```bash
git add qml/components/StatCard.qml
git commit -m "feat: add StatCard component for statistics display"
```

---

## Task 5: Create ChartBar Component for Week Trend

**Files:**
- Create: `qml/components/ChartBar.qml`

- [ ] **Step 1: Create ChartBar.qml**

Create file with this content:

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import QtCharts 6.0

Rectangle {
    id: root
    
    property var weekData: []  // [{date: "2026-06-09", duration: 9000}, ...]
    
    width: 600
    height: 300
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1
    
    ChartView {
        anchors.fill: parent
        anchors.margins: 10
        antialiasing: true
        backgroundColor: "transparent"
        legend.visible: false
        
        BarSeries {
            id: barSeries
            axisX: BarCategoryAxis {
                categories: {
                    var cats = [];
                    for (var i = 0; i < root.weekData.length; i++) {
                        var d = new Date(root.weekData[i].date);
                        var weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
                        cats.push(weekdays[d.getDay()]);
                    }
                    return cats;
                }
                labelsColor: "#5d4e37"
            }
            axisY: ValueAxis {
                min: 0
                max: {
                    var maxVal = 0;
                    for (var i = 0; i < root.weekData.length; i++) {
                        var hours = root.weekData[i].duration / 3600;
                        if (hours > maxVal) maxVal = hours;
                    }
                    return Math.ceil(maxVal) + 1;
                }
                tickCount: 5
                labelsColor: "#5d4e37"
                labelFormat: "%.1f h"
            }
            
            BarSet {
                id: durationSet
                color: "#d4a574"
                borderColor: "#5d4e37"
                borderWidth: 1
                values: {
                    var vals = [];
                    for (var i = 0; i < root.weekData.length; i++) {
                        vals.push(root.weekData[i].duration / 3600);
                    }
                    return vals;
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and test**

```bash
cd build
cmake --build .
```

Expected: Builds successfully with Qt Charts

- [ ] **Step 3: Commit**

```bash
git add qml/components/ChartBar.qml
git commit -m "feat: add bar chart component for week trend visualization"
```

---

## Task 6: Create ChartPie Component for Category Distribution

**Files:**
- Create: `qml/components/ChartPie.qml`

- [ ] **Step 1: Create ChartPie.qml**

Create file with this content:

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import QtCharts 6.0

Rectangle {
    id: root
    
    property var categoryData: []  // [{name: "数据结构", duration: 5400, percentage: 35.5}, ...]
    
    width: 400
    height: 300
    radius: 6
    color: "#faf6ee"
    border.color: "#e8dfc8"
    border.width: 1
    
    Row {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 20
        
        ChartView {
            width: parent.width * 0.6
            height: parent.height
            antialiasing: true
            backgroundColor: "transparent"
            legend.visible: false
            
            PieSeries {
                id: pieSeries
                
                Component.onCompleted: {
                    var colors = ["#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c"];
                    for (var i = 0; i < root.categoryData.length; i++) {
                        var slice = pieSeries.append(
                            root.categoryData[i].name,
                            root.categoryData[i].duration
                        );
                        slice.color = colors[i % colors.length];
                        slice.borderColor = "#5d4e37";
                        slice.borderWidth = 1;
                    }
                }
            }
        }
        
        Column {
            width: parent.width * 0.35
            height: parent.height
            spacing: 8
            
            Repeater {
                model: root.categoryData
                
                Row {
                    spacing: 8
                    
                    Rectangle {
                        width: 12
                        height: 12
                        radius: 2
                        color: {
                            var colors = ["#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c"];
                            return colors[index % colors.length];
                        }
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    
                    Column {
                        spacing: 2
                        
                        Text {
                            text: modelData.name
                            font.pixelSize: 13
                            color: "#5d4e37"
                        }
                        
                        Text {
                            text: Math.floor(modelData.duration / 3600) + "h " + 
                                  Math.floor((modelData.duration % 3600) / 60) + "m (" + 
                                  modelData.percentage.toFixed(1) + "%)"
                            font.pixelSize: 11
                            color: "#8b7355"
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and test**

```bash
cd build
cmake --build .
```

Expected: Builds successfully

- [ ] **Step 3: Commit**

```bash
git add qml/components/ChartPie.qml
git commit -m "feat: add pie chart component for category distribution"
```

---

## Task 7: Create StatisticsView with Complete Dashboard

**Files:**
- Create: `qml/views/StatisticsView.qml`

- [ ] **Step 1: Create StatisticsView.qml**

Create file with this content:

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import "../components"

Rectangle {
    id: root
    
    color: "#fffef9"
    
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        
        Column {
            width: parent.width
            padding: 30
            spacing: 30
            
            // Header
            Text {
                text: "数据统计"
                font.pixelSize: 24
                font.bold: true
                color: "#5d4e37"
            }
            
            // Today Stats Cards
            Row {
                spacing: 20
                
                StatCard {
                    title: "今日专注"
                    value: {
                        var stats = StatisticsService.getTodayStats();
                        var hours = Math.floor(stats.totalDuration / 3600);
                        var minutes = Math.floor((stats.totalDuration % 3600) / 60);
                        return hours + "." + Math.floor(minutes / 6);
                    }
                    unit: "小时"
                    subtitle: ""
                }
                
                StatCard {
                    title: "任务完成"
                    value: {
                        var stats = StatisticsService.getTodayStats();
                        return stats.completedTasks.toString();
                    }
                    unit: "/ " + StatisticsService.getTodayStats().totalTasks
                    subtitle: "完成率 " + (StatisticsService.getTodayStats().completionRate * 100).toFixed(0) + "%"
                }
                
                StatCard {
                    title: "本周累计"
                    value: {
                        var weekStats = StatisticsService.getWeekStats();
                        var total = 0;
                        for (var i = 0; i < weekStats.length; i++) {
                            total += weekStats[i].duration;
                        }
                        return (total / 3600).toFixed(1);
                    }
                    unit: "小时"
                    subtitle: ""
                }
            }
            
            // Week Trend Chart
            Column {
                width: parent.width - 60
                spacing: 10
                
                Text {
                    text: "本周专注趋势"
                    font.pixelSize: 18
                    font.bold: true
                    color: "#5d4e37"
                }
                
                ChartBar {
                    width: parent.width
                    weekData: StatisticsService.getWeekStats()
                }
            }
            
            // Category Distribution Chart
            Column {
                width: parent.width - 60
                spacing: 10
                
                Text {
                    text: "科目时间分配"
                    font.pixelSize: 18
                    font.bold: true
                    color: "#5d4e37"
                }
                
                ChartPie {
                    width: parent.width
                    categoryData: {
                        var today = new Date();
                        var weekStart = new Date(today);
                        weekStart.setDate(today.getDate() - today.getDay());
                        var stats = StatisticsService.getCategoryStats(
                            Qt.formatDate(weekStart, "yyyy-MM-dd"),
                            Qt.formatDate(today, "yyyy-MM-dd")
                        );
                        return stats.categories || [];
                    }
                }
            }
        }
    }
    
    // Auto-refresh when view becomes visible
    Component.onCompleted: {
        refreshTimer.start();
    }
    
    Timer {
        id: refreshTimer
        interval: 60000  // Refresh every minute
        running: false
        repeat: true
        onTriggered: {
            // Trigger re-evaluation of bindings
            root.visible = root.visible;
        }
    }
}
```

- [ ] **Step 2: Register StatCard, ChartBar, ChartPie in qmldir**

If `qml/components/qmldir` doesn't exist, create it:

```
StatCard 1.0 StatCard.qml
ChartBar 1.0 ChartBar.qml
ChartPie 1.0 ChartPie.qml
TaskItem 1.0 TaskItem.qml
AddTaskDialog 1.0 AddTaskDialog.qml
Sidebar 1.0 Sidebar.qml
```

- [ ] **Step 3: Build and test**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: App runs, can navigate to statistics view (once integrated)

- [ ] **Step 4: Commit**

```bash
git add qml/views/StatisticsView.qml qml/components/qmldir
git commit -m "feat: create complete statistics dashboard with charts"
```

---

## Task 8: Create WeekPlanView

**Files:**
- Create: `qml/views/WeekPlanView.qml`

- [ ] **Step 1: Create WeekPlanView.qml**

Create file with this content:

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import "../components"

Rectangle {
    id: root
    
    color: "#fffef9"
    
    property date weekStart: {
        var today = new Date();
        var start = new Date(today);
        start.setDate(today.getDate() - today.getDay() + 1);  // Monday
        return start;
    }
    
    Column {
        anchors.fill: parent
        padding: 30
        spacing: 20
        
        // Header with week navigation
        Row {
            width: parent.width - 60
            spacing: 20
            
            Text {
                text: "本周计划"
                font.pixelSize: 24
                font.bold: true
                color: "#5d4e37"
                anchors.verticalCenter: parent.verticalCenter
            }
            
            Item { Layout.fillWidth: true; width: 1 }
            
            Row {
                spacing: 10
                anchors.verticalCenter: parent.verticalCenter
                
                Button {
                    text: "◀"
                    onClicked: {
                        var newStart = new Date(root.weekStart);
                        newStart.setDate(newStart.getDate() - 7);
                        root.weekStart = newStart;
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        radius: 4
                    }
                }
                
                Text {
                    text: Qt.formatDate(root.weekStart, "yyyy-MM-dd") + " - " + 
                          Qt.formatDate(new Date(root.weekStart.getTime() + 6 * 86400000), "yyyy-MM-dd")
                    font.pixelSize: 14
                    color: "#5d4e37"
                    anchors.verticalCenter: parent.verticalCenter
                }
                
                Button {
                    text: "▶"
                    onClicked: {
                        var newStart = new Date(root.weekStart);
                        newStart.setDate(newStart.getDate() + 7);
                        root.weekStart = newStart;
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        radius: 4
                    }
                }
                
                Button {
                    text: "本周"
                    onClicked: {
                        var today = new Date();
                        var start = new Date(today);
                        start.setDate(today.getDate() - today.getDay() + 1);
                        root.weekStart = start;
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        radius: 4
                    }
                }
            }
        }
        
        // Week days grid
        ScrollView {
            width: parent.width - 60
            height: parent.height - 100
            contentWidth: availableWidth
            
            Column {
                width: parent.width
                spacing: 15
                
                Repeater {
                    model: 7
                    
                    Column {
                        width: parent.width
                        spacing: 10
                        
                        Rectangle {
                            width: parent.width
                            height: 1
                            color: "#e8dfc8"
                            visible: index > 0
                        }
                        
                        Text {
                            text: {
                                var dayDate = new Date(root.weekStart);
                                dayDate.setDate(dayDate.getDate() + index);
                                var weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
                                return weekdays[index] + " " + Qt.formatDate(dayDate, "MM-dd");
                            }
                            font.pixelSize: 16
                            font.bold: true
                            color: "#5d4e37"
                        }
                        
                        Column {
                            width: parent.width
                            spacing: 8
                            
                            Repeater {
                                model: {
                                    var dayDate = new Date(root.weekStart);
                                    dayDate.setDate(dayDate.getDate() + index);
                                    return TaskManager.getWeekTasks(dayDate).filter(function(task) {
                                        return Qt.formatDate(task.date, "yyyy-MM-dd") === Qt.formatDate(dayDate, "yyyy-MM-dd");
                                    });
                                }
                                
                                TaskItem {
                                    width: parent.width
                                    taskId: modelData.id
                                    taskTitle: modelData.title
                                    taskCategory: modelData.category
                                    taskCompleted: modelData.completed
                                }
                            }
                            
                            Text {
                                text: "暂无任务"
                                font.pixelSize: 13
                                color: "#8b7355"
                                visible: parent.children.length === 1
                            }
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and test**

```bash
cd build
cmake --build .
```

Expected: Builds successfully

- [ ] **Step 3: Commit**

```bash
git add qml/views/WeekPlanView.qml
git commit -m "feat: create week plan view with day-by-day task display"
```

---

## Task 9: Create MonthGoalView

**Files:**
- Create: `qml/views/MonthGoalView.qml`

- [ ] **Step 1: Create MonthGoalView.qml**

Create file with this content:

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import QtQuick.Layouts 6.0

Rectangle {
    id: root
    
    color: "#fffef9"
    
    property int currentYear: new Date().getFullYear()
    property int currentMonth: new Date().getMonth() + 1
    
    Column {
        anchors.fill: parent
        padding: 30
        spacing: 20
        
        // Header with month navigation
        Row {
            width: parent.width - 60
            spacing: 20
            
            Text {
                text: "月度目标"
                font.pixelSize: 24
                font.bold: true
                color: "#5d4e37"
                anchors.verticalCenter: parent.verticalCenter
            }
            
            Item { Layout.fillWidth: true; width: 1 }
            
            Row {
                spacing: 10
                anchors.verticalCenter: parent.verticalCenter
                
                Button {
                    text: "◀"
                    onClicked: {
                        if (root.currentMonth === 1) {
                            root.currentMonth = 12;
                            root.currentYear--;
                        } else {
                            root.currentMonth--;
                        }
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        radius: 4
                    }
                }
                
                Text {
                    text: root.currentYear + "年" + root.currentMonth + "月"
                    font.pixelSize: 16
                    color: "#5d4e37"
                    anchors.verticalCenter: parent.verticalCenter
                }
                
                Button {
                    text: "▶"
                    onClicked: {
                        if (root.currentMonth === 12) {
                            root.currentMonth = 1;
                            root.currentYear++;
                        } else {
                            root.currentMonth++;
                        }
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        radius: 4
                    }
                }
                
                Button {
                    text: "本月"
                    onClicked: {
                        var today = new Date();
                        root.currentYear = today.getFullYear();
                        root.currentMonth = today.getMonth() + 1;
                    }
                    background: Rectangle {
                        color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        radius: 4
                    }
                }
            }
        }
        
        // Month calendar grid
        ScrollView {
            width: parent.width - 60
            height: parent.height - 100
            contentWidth: availableWidth
            
            Column {
                width: parent.width
                spacing: 20
                
                // Summary stats
                Row {
                    width: parent.width
                    spacing: 20
                    
                    Rectangle {
                        width: (parent.width - 40) / 3
                        height: 80
                        radius: 6
                        color: "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        
                        Column {
                            anchors.centerIn: parent
                            spacing: 5
                            
                            Text {
                                text: "本月任务"
                                font.pixelSize: 13
                                color: "#8b7355"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                            
                            Text {
                                text: {
                                    var tasks = TaskManager.getMonthTasks(root.currentYear, root.currentMonth);
                                    return tasks.length.toString();
                                }
                                font.pixelSize: 28
                                font.bold: true
                                color: "#5d4e37"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                    
                    Rectangle {
                        width: (parent.width - 40) / 3
                        height: 80
                        radius: 6
                        color: "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        
                        Column {
                            anchors.centerIn: parent
                            spacing: 5
                            
                            Text {
                                text: "已完成"
                                font.pixelSize: 13
                                color: "#8b7355"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                            
                            Text {
                                text: {
                                    var tasks = TaskManager.getMonthTasks(root.currentYear, root.currentMonth);
                                    var completed = tasks.filter(function(t) { return t.completed; }).length;
                                    return completed.toString();
                                }
                                font.pixelSize: 28
                                font.bold: true
                                color: "#5d4e37"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                    
                    Rectangle {
                        width: (parent.width - 40) / 3
                        height: 80
                        radius: 6
                        color: "#faf6ee"
                        border.color: "#e8dfc8"
                        border.width: 1
                        
                        Column {
                            anchors.centerIn: parent
                            spacing: 5
                            
                            Text {
                                text: "完成率"
                                font.pixelSize: 13
                                color: "#8b7355"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                            
                            Text {
                                text: {
                                    var tasks = TaskManager.getMonthTasks(root.currentYear, root.currentMonth);
                                    if (tasks.length === 0) return "0%";
                                    var completed = tasks.filter(function(t) { return t.completed; }).length;
                                    return Math.round(completed * 100 / tasks.length) + "%";
                                }
                                font.pixelSize: 28
                                font.bold: true
                                color: "#5d4e37"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }
                }
                
                // Task list grouped by date
                Column {
                    width: parent.width
                    spacing: 15
                    
                    Repeater {
                        model: {
                            var tasks = TaskManager.getMonthTasks(root.currentYear, root.currentMonth);
                            var grouped = {};
                            for (var i = 0; i < tasks.length; i++) {
                                var dateStr = Qt.formatDate(tasks[i].date, "yyyy-MM-dd");
                                if (!grouped[dateStr]) grouped[dateStr] = [];
                                grouped[dateStr].push(tasks[i]);
                            }
                            var result = [];
                            for (var date in grouped) {
                                result.push({date: date, tasks: grouped[date]});
                            }
                            result.sort(function(a, b) { return a.date < b.date ? -1 : 1; });
                            return result;
                        }
                        
                        Column {
                            width: parent.width
                            spacing: 10
                            
                            Text {
                                text: modelData.date
                                font.pixelSize: 16
                                font.bold: true
                                color: "#5d4e37"
                            }
                            
                            Column {
                                width: parent.width
                                spacing: 8
                                
                                Repeater {
                                    model: modelData.tasks
                                    
                                    Rectangle {
                                        width: parent.width
                                        height: 40
                                        radius: 4
                                        color: "#faf6ee"
                                        border.color: "#e8dfc8"
                                        border.width: 1
                                        
                                        Row {
                                            anchors.fill: parent
                                            anchors.margins: 10
                                            spacing: 10
                                            
                                            CheckBox {
                                                checked: modelData.completed
                                                anchors.verticalCenter: parent.verticalCenter
                                                onClicked: {
                                                    TaskManager.completeTask(modelData.id);
                                                }
                                            }
                                            
                                            Text {
                                                text: modelData.title
                                                font.pixelSize: 14
                                                color: modelData.completed ? "#8b7355" : "#5d4e37"
                                                font.strikeout: modelData.completed
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            
                                            Rectangle {
                                                width: categoryText.width + 12
                                                height: 20
                                                radius: 3
                                                color: "#e8dfc8"
                                                visible: modelData.category !== ""
                                                anchors.verticalCenter: parent.verticalCenter
                                                
                                                Text {
                                                    id: categoryText
                                                    text: modelData.category
                                                    font.pixelSize: 11
                                                    color: "#5d4e37"
                                                    anchors.centerIn: parent
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and test**

```bash
cd build
cmake --build .
```

Expected: Builds successfully

- [ ] **Step 3: Commit**

```bash
git add qml/views/MonthGoalView.qml
git commit -m "feat: create month goal view with task overview and statistics"
```

---

## Task 10: Update MainWindow to Integrate New Views

**Files:**
- Modify: `qml/MainWindow.qml`
- Modify: `qml/components/Sidebar.qml`

- [ ] **Step 1: Add new views to MainWindow StackLayout**

Read the current MainWindow.qml to locate the StackLayout, then add the new view imports and items:

At the top, add imports:
```qml
import "./views/WeekPlanView.qml"
import "./views/StatisticsView.qml"
import "./views/MonthGoalView.qml"
```

In the StackLayout section, add after existing views:
```qml
WeekPlanView {
    id: weekPlanView
}

StatisticsView {
    id: statisticsView
}

MonthGoalView {
    id: monthGoalView
}
```

- [ ] **Step 2: Update Sidebar navigation items**

Add to the Sidebar.qml navigation list:

```qml
ListModel {
    ListElement { name: "今日任务"; icon: "📋"; viewIndex: 0 }
    ListElement { name: "本周计划"; icon: "📅"; viewIndex: 1 }
    ListElement { name: "月度目标"; icon: "🎯"; viewIndex: 2 }
    ListElement { name: "数据统计"; icon: "📊"; viewIndex: 3 }
    ListElement { name: "专注"; icon: "⏱️"; viewIndex: 4 }
}
```

Update the click handler to switch views:
```qml
onClicked: {
    stackLayout.currentIndex = model.viewIndex;
}
```

- [ ] **Step 3: Build and test navigation**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: All views are accessible from sidebar, navigation works smoothly

- [ ] **Step 4: Test each view**

Manual testing checklist:
- [ ] Click "本周计划" - should show week view with current week
- [ ] Click week navigation buttons - should change weeks
- [ ] Click "月度目标" - should show month overview
- [ ] Click month navigation buttons - should change months
- [ ] Click "数据统计" - should show charts and stats
- [ ] Verify all charts render correctly with existing data

- [ ] **Step 5: Commit**

```bash
git add qml/MainWindow.qml qml/components/Sidebar.qml
git commit -m "feat: integrate week plan, month goal, and statistics views into main window"
```

---

## Task 11: Final Integration Testing and Polish

**Files:**
- Test: All views and functionality

- [ ] **Step 1: Create test data**

Add some test tasks and focus sessions to verify all features:

From the app:
1. Add 3-5 tasks for today with different categories
2. Add 5-10 tasks spread across this week
3. Add 10-15 tasks for the current month
4. Complete some tasks
5. Start and complete 2-3 focus sessions

- [ ] **Step 2: Test complete user flow**

Walk through the complete application:

1. **Today view**:
   - Add a task
   - Mark a task complete
   - Start focus on a task
   - Verify focus page opens

2. **Focus view**:
   - Verify timer counts up
   - Test pause/resume
   - Complete focus session
   - Verify returns to task view

3. **Week plan view**:
   - Verify current week shows correctly
   - Navigate to previous/next week
   - Verify tasks display on correct days
   - Jump back to "本周"

4. **Month goal view**:
   - Verify current month statistics
   - Navigate to previous/next month
   - Verify task grouping by date
   - Check completion rate calculation

5. **Statistics view**:
   - Verify today stats cards show correct data
   - Verify week trend bar chart displays
   - Verify category pie chart shows distribution
   - Check data formatting (hours, percentages)

- [ ] **Step 3: Verify visual consistency**

Check that all views follow the warm paper theme:
- [ ] Background colors match (#fffef9, #faf8f3, #faf6ee)
- [ ] Text colors consistent (#5d4e37, #8b7355)
- [ ] Border colors match (#e8dfc8)
- [ ] Accent color used appropriately (#d4a574)
- [ ] Border radius consistent (4-6px)
- [ ] Spacing feels natural and consistent

- [ ] **Step 4: Performance check**

Test with more data:
- Add 50+ tasks for the month
- Verify scrolling is smooth
- Verify view switches are instant
- Check that charts render quickly

- [ ] **Step 5: Edge case testing**

Test boundary conditions:
- [ ] Empty states (no tasks, no focus sessions)
- [ ] Month with no tasks
- [ ] Category with no focus time
- [ ] Tasks without categories
- [ ] Future dates
- [ ] Past dates

- [ ] **Step 6: Fix any issues found**

If you discover bugs or visual inconsistencies during testing:
1. Document the issue
2. Fix it
3. Re-test
4. Commit the fix with descriptive message

- [ ] **Step 7: Final commit**

```bash
git add .
git commit -m "test: complete phase 2 integration testing and polish"
```

- [ ] **Step 8: Tag the release**

```bash
git tag -a v0.2.0 -m "Phase 2: Week plan, statistics dashboard, and month view"
git push origin v0.2.0
```

---

## Completion Checklist

Phase 2 is complete when:

- [ ] All 11 tasks are finished
- [ ] Qt Charts dependency is working
- [ ] TaskManager has week/month query methods
- [ ] StatisticsService calculates category stats
- [ ] All three chart components render correctly
- [ ] WeekPlanView shows tasks by day with navigation
- [ ] MonthGoalView shows monthly overview with stats
- [ ] StatisticsView displays complete dashboard
- [ ] All views are integrated into MainWindow
- [ ] Sidebar navigation works for all views
- [ ] Visual theme is consistent across all views
- [ ] No crashes or errors during normal usage
- [ ] All commits are clean with descriptive messages

---

## Next Steps (Phase 3)

After Phase 2 is complete, consider:

1. **Visual polish**:
   - Task completion animations
   - Page transition effects
   - Loading states for charts

2. **Category management**:
   - Custom category colors
   - Category CRUD operations
   - Category presets for exam subjects

3. **Data export**:
   - Export statistics to CSV
   - Backup/restore functionality

4. **Advanced features**:
   - Study streak tracking
   - Goal setting with reminders
   - Customizable focus durations

