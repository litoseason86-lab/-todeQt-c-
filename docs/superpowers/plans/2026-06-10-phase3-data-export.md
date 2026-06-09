# Phase 3.2: 数据导出功能实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现数据导出功能，支持将任务和专注记录导出为 CSV 格式，包含日期范围筛选和完整科目信息

**Architecture:** 创建 ExportService 单例服务处理 CSV 生成，实现 UTF-8 编码和字段转义，创建 ExportDialog 提供用户界面，集成到侧边栏或设置页

**Tech Stack:** Qt 6, C++17, QML, QTextStream, FileDialog

---

## File Structure Overview

### New Files
- `src/services/ExportService.h` - 数据导出服务头文件
- `src/services/ExportService.cpp` - 数据导出服务实现
- `qml/components/ExportDialog.qml` - 数据导出对话框

### Modified Files
- `qml/components/Sidebar.qml` - 添加数据导出入口
- `src/main.cpp` - 注册 ExportService 到 QML

---

## Tasks

## Task 1: 创建 ExportService 服务框架

**Files:**
- Create: `src/services/ExportService.h`
- Create: `src/services/ExportService.cpp`

- [ ] **Step 1: 创建 ExportService.h**

```cpp
#ifndef EXPORTSERVICE_H
#define EXPORTSERVICE_H

#include <QObject>
#include <QDate>
#include <QString>

class ExportService : public QObject
{
    Q_OBJECT
    
public:
    static ExportService* instance();
    
    // Export methods
    Q_INVOKABLE bool exportTasks(const QDate& startDate, 
                                  const QDate& endDate, 
                                  const QString& filePath);
    
    Q_INVOKABLE bool exportFocusSessions(const QDate& startDate, 
                                         const QDate& endDate, 
                                         const QString& filePath);
    
    Q_INVOKABLE bool exportAll(const QDate& startDate, 
                               const QDate& endDate, 
                               const QString& dirPath);
    
    // Helper methods
    Q_INVOKABLE QString generateFileName(const QString& type,
                                         const QDate& startDate,
                                         const QDate& endDate);
    
signals:
    void exportProgress(int current, int total);
    void exportCompleted(bool success, const QString& message);
    
private:
    explicit ExportService(QObject* parent = nullptr);
    static ExportService* s_instance;
    
    QString escapeCSVField(const QString& field);
    QString formatDateTime(const QDateTime& dt);
};

#endif // EXPORTSERVICE_H
```

- [ ] **Step 2: 创建 ExportService.cpp 框架**

```cpp
#include "ExportService.h"
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QFile>
#include <QTextStream>
#include <QDir>

ExportService* ExportService::s_instance = nullptr;

ExportService::ExportService(QObject* parent)
    : QObject(parent)
{
}

ExportService* ExportService::instance()
{
    if (!s_instance) {
        s_instance = new ExportService();
    }
    return s_instance;
}

QString ExportService::escapeCSVField(const QString& field)
{
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
        QString escaped = field;
        escaped.replace("\"", "\"\"");
        return QString("\"%1\"").arg(escaped);
    }
    return field;
}

QString ExportService::formatDateTime(const QDateTime& dt)
{
    return dt.toString("yyyy-MM-dd HH:mm:ss");
}

QString ExportService::generateFileName(const QString& type, 
                                        const QDate& startDate, 
                                        const QDate& endDate)
{
    QString start = startDate.toString("yyyyMMdd");
    QString end = endDate.toString("yyyyMMdd");
    return QString("%1_%2_%3.csv").arg(type, start, end);
}
```

- [ ] **Step 3: 更新 CMakeLists.txt**

在 CMakeLists.txt 的源文件列表中添加：

```cmake
src/services/ExportService.cpp
src/services/ExportService.h
```

- [ ] **Step 4: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 5: 提交**

```bash
git add src/services/ExportService.h src/services/ExportService.cpp CMakeLists.txt
git commit -m "feat: create ExportService skeleton with helper methods"
```

---

## Task 2: 实现任务导出功能

**Files:**
- Modify: `src/services/ExportService.cpp`

- [ ] **Step 1: 实现 exportTasks 方法**

在 `ExportService.cpp` 中添加：

```cpp
bool ExportService::exportTasks(const QDate& startDate, 
                                const QDate& endDate, 
                                const QString& filePath)
{
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        QString error = QString("无法创建文件: %1").arg(file.errorString());
        emit exportCompleted(false, error);
        return false;
    }
    
    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    
    // Write CSV header
    out << "ID,标题,科目,日期,完成状态,创建时间\n";
    
    // Query tasks with category information
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(R"(
        SELECT t.id, t.title, t.date, t.completed, t.created_at,
               c.name as category_name
        FROM tasks t
        LEFT JOIN categories c ON t.category_id = c.id
        WHERE t.date >= ? AND t.date <= ?
        ORDER BY t.date, t.created_at
    )");
    query.addBindValue(startDate);
    query.addBindValue(endDate);
    
    if (!query.exec()) {
        file.close();
        QString error = QString("数据库查询失败: %1").arg(query.lastError().text());
        emit exportCompleted(false, error);
        return false;
    }
    
    int total = 0;
    int current = 0;
    
    // Count total records
    if (query.last()) {
        total = query.at() + 1;
        query.first();
        query.previous();
    }
    
    // Write data rows
    while (query.next()) {
        int id = query.value(0).toInt();
        QString title = escapeCSVField(query.value(1).toString());
        QString date = query.value(2).toDate().toString("yyyy-MM-dd");
        QString completed = query.value(3).toBool() ? "已完成" : "未完成";
        QString createdAt = formatDateTime(query.value(4).toDateTime());
        QString category = query.value(5).isNull() ? "未分类" : escapeCSVField(query.value(5).toString());
        
        out << QString("%1,%2,%3,%4,%5,%6\n")
               .arg(id)
               .arg(title)
               .arg(category)
               .arg(date)
               .arg(completed)
               .arg(createdAt);
        
        current++;
        emit exportProgress(current, total);
    }
    
    file.close();
    
    QString message = QString("成功导出 %1 条任务记录").arg(current);
    emit exportCompleted(true, message);
    return true;
}
```

- [ ] **Step 2: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 3: 提交**

```bash
git add src/services/ExportService.cpp
git commit -m "feat: implement exportTasks method with CSV generation"
```

---

## Task 3: 实现专注记录导出功能

**Files:**
- Modify: `src/services/ExportService.cpp`

- [ ] **Step 1: 实现 exportFocusSessions 方法**

在 `ExportService.cpp` 中添加：

```cpp
bool ExportService::exportFocusSessions(const QDate& startDate, 
                                        const QDate& endDate, 
                                        const QString& filePath)
{
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        QString error = QString("无法创建文件: %1").arg(file.errorString());
        emit exportCompleted(false, error);
        return false;
    }
    
    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    
    // Write CSV header
    out << "ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n";
    
    // Query focus sessions with task and category information
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(R"(
        SELECT f.id, f.task_id, f.start_time, f.end_time, f.duration,
               t.title as task_title,
               c.name as category_name
        FROM focus_sessions f
        LEFT JOIN tasks t ON f.task_id = t.id
        LEFT JOIN categories c ON t.category_id = c.id
        WHERE DATE(f.start_time) >= ? AND DATE(f.start_time) <= ?
        ORDER BY f.start_time
    )");
    query.addBindValue(startDate);
    query.addBindValue(endDate);
    
    if (!query.exec()) {
        file.close();
        QString error = QString("数据库查询失败: %1").arg(query.lastError().text());
        emit exportCompleted(false, error);
        return false;
    }
    
    int total = 0;
    int current = 0;
    
    // Count total records
    if (query.last()) {
        total = query.at() + 1;
        query.first();
        query.previous();
    }
    
    // Write data rows
    while (query.next()) {
        int id = query.value(0).toInt();
        int taskId = query.value(1).isNull() ? -1 : query.value(1).toInt();
        QString startTime = formatDateTime(query.value(2).toDateTime());
        QString endTime = query.value(3).isNull() ? "" : formatDateTime(query.value(3).toDateTime());
        int durationSeconds = query.value(4).toInt();
        int durationMinutes = durationSeconds / 60;
        QString taskTitle = query.value(5).isNull() ? "未关联任务" : escapeCSVField(query.value(5).toString());
        QString category = query.value(6).isNull() ? "未分类" : escapeCSVField(query.value(6).toString());
        
        out << QString("%1,%2,%3,%4,%5,%6,%7\n")
               .arg(id)
               .arg(taskId)
               .arg(taskTitle)
               .arg(category)
               .arg(startTime)
               .arg(endTime)
               .arg(durationMinutes);
        
        current++;
        emit exportProgress(current, total);
    }
    
    file.close();
    
    QString message = QString("成功导出 %1 条专注记录").arg(current);
    emit exportCompleted(true, message);
    return true;
}
```

- [ ] **Step 2: 实现 exportAll 方法**

在 `ExportService.cpp` 中添加：

```cpp
bool ExportService::exportAll(const QDate& startDate, 
                              const QDate& endDate, 
                              const QString& dirPath)
{
    // Ensure directory exists
    QDir dir(dirPath);
    if (!dir.exists()) {
        QString error = QString("目录不存在: %1").arg(dirPath);
        emit exportCompleted(false, error);
        return false;
    }
    
    // Generate file paths
    QString tasksFile = dir.filePath(generateFileName("tasks", startDate, endDate));
    QString sessionsFile = dir.filePath(generateFileName("focus_sessions", startDate, endDate));
    
    // Export tasks
    if (!exportTasks(startDate, endDate, tasksFile)) {
        return false;
    }
    
    // Export focus sessions
    if (!exportFocusSessions(startDate, endDate, sessionsFile)) {
        return false;
    }
    
    QString message = QString("成功导出所有数据到:\n%1\n%2").arg(tasksFile, sessionsFile);
    emit exportCompleted(true, message);
    return true;
}
```

- [ ] **Step 3: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 4: 提交**

```bash
git add src/services/ExportService.cpp
git commit -m "feat: implement exportFocusSessions and exportAll methods"
```

---

## Task 4: 注册 ExportService 到 QML

**Files:**
- Modify: `src/main.cpp`

- [ ] **Step 1: 添加 ExportService 头文件**

在 `main.cpp` 顶部添加 include：

```cpp
#include "services/ExportService.h"
```

- [ ] **Step 2: 注册到 QML 引擎**

在 `main()` 函数中，找到其他服务注册的位置，添加：

```cpp
engine.rootContext()->setContextProperty("ExportService", ExportService::instance());
```

- [ ] **Step 3: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 4: 提交**

```bash
git add src/main.cpp
git commit -m "feat: register ExportService to QML context"
```

---

## Task 5: 创建 ExportDialog 组件

**Files:**
- Create: `qml/components/ExportDialog.qml`

- [ ] **Step 1: 创建 ExportDialog.qml 框架**

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import QtQuick.Layouts 6.0
import QtQuick.Dialogs

Dialog {
    id: dialog
    
    title: "数据导出"
    modal: true
    width: 450
    height: 400
    
    property date currentDate: new Date()
    property date firstDayOfMonth: new Date(currentDate.getFullYear(), currentDate.getMonth(), 1)
    
    background: Rectangle {
        color: "#fffef9"
        radius: 6
        border.color: "#e8dfc8"
        border.width: 1
    }
    
    ColumnLayout {
        anchors.fill: parent
        spacing: 20
        
        // Date range section
        GroupBox {
            Layout.fillWidth: true
            title: "日期范围"
            
            background: Rectangle {
                color: "#faf6ee"
                radius: 4
                border.color: "#e8dfc8"
                border.width: 1
            }
            
            ColumnLayout {
                anchors.fill: parent
                spacing: 10
                
                // Quick selection buttons
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    
                    Button {
                        text: "本周"
                        onClicked: setDateRangeThisWeek()
                        background: Rectangle {
                            color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                            radius: 4
                            border.color: "#e8dfc8"
                            border.width: 1
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#5d4e37"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    
                    Button {
                        text: "本月"
                        onClicked: setDateRangeThisMonth()
                        background: Rectangle {
                            color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                            radius: 4
                            border.color: "#e8dfc8"
                            border.width: 1
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#5d4e37"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    
                    Button {
                        text: "上月"
                        onClicked: setDateRangeLastMonth()
                        background: Rectangle {
                            color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                            radius: 4
                            border.color: "#e8dfc8"
                            border.width: 1
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#5d4e37"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    
                    Button {
                        text: "全部"
                        onClicked: setDateRangeAll()
                        background: Rectangle {
                            color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                            radius: 4
                            border.color: "#e8dfc8"
                            border.width: 1
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#5d4e37"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
                
                // Date inputs
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    
                    Label {
                        text: "开始日期:"
                        color: "#5d4e37"
                        font.pixelSize: 13
                    }
                    
                    TextField {
                        id: startDateInput
                        Layout.fillWidth: true
                        text: Qt.formatDate(dialog.firstDayOfMonth, "yyyy-MM-dd")
                        font.pixelSize: 13
                        
                        background: Rectangle {
                            color: "#faf6ee"
                            radius: 4
                            border.color: parent.activeFocus ? "#d4a574" : "#e8dfc8"
                            border.width: 1
                        }
                    }
                }
                
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    
                    Label {
                        text: "结束日期:"
                        color: "#5d4e37"
                        font.pixelSize: 13
                    }
                    
                    TextField {
                        id: endDateInput
                        Layout.fillWidth: true
                        text: Qt.formatDate(dialog.currentDate, "yyyy-MM-dd")
                        font.pixelSize: 13
                        
                        background: Rectangle {
                            color: "#faf6ee"
                            radius: 4
                            border.color: parent.activeFocus ? "#d4a574" : "#e8dfc8"
                            border.width: 1
                        }
                    }
                }
            }
        }
        
        // Export content selection
        GroupBox {
            Layout.fillWidth: true
            title: "导出内容"
            
            background: Rectangle {
                color: "#faf6ee"
                radius: 4
                border.color: "#e8dfc8"
                border.width: 1
            }
            
            ColumnLayout {
                anchors.fill: parent
                spacing: 8
                
                RadioButton {
                    id: exportAllRadio
                    text: "全部（任务 + 专注记录）"
                    checked: true
                    font.pixelSize: 13
                }
                
                RadioButton {
                    id: exportTasksRadio
                    text: "仅任务"
                    font.pixelSize: 13
                }
                
                RadioButton {
                    id: exportSessionsRadio
                    text: "仅专注记录"
                    font.pixelSize: 13
                }
            }
        }
        
        Item { Layout.fillHeight: true }
        
        // Status message
        Text {
            id: statusMessage
            Layout.fillWidth: true
            text: ""
            color: "#5d4e37"
            font.pixelSize: 12
            wrapMode: Text.Wrap
            visible: text !== ""
        }
        
        // Action buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            
            Button {
                text: "取消"
                Layout.fillWidth: true
                onClicked: dialog.close()
                
                background: Rectangle {
                    color: parent.pressed ? "#e8dfc8" : "#faf6ee"
                    radius: 4
                    border.color: "#e8dfc8"
                    border.width: 1
                }
                
                contentItem: Text {
                    text: parent.text
                    color: "#5d4e37"
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            
            Button {
                text: "导出"
                Layout.fillWidth: true
                onClicked: performExport()
                
                background: Rectangle {
                    color: parent.pressed ? "#c9956e" : "#d4a574"
                    radius: 4
                }
                
                contentItem: Text {
                    text: parent.text
                    color: "#ffffff"
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
```

- [ ] **Step 2: 添加日期范围快捷方法**

在 ExportDialog.qml 中添加：

```qml
function setDateRangeThisWeek() {
    var today = new Date()
    var dayOfWeek = today.getDay() // 0 = Sunday
    var monday = new Date(today)
    monday.setDate(today.getDate() - (dayOfWeek === 0 ? 6 : dayOfWeek - 1))
    
    startDateInput.text = Qt.formatDate(monday, "yyyy-MM-dd")
    endDateInput.text = Qt.formatDate(today, "yyyy-MM-dd")
}

function setDateRangeThisMonth() {
    var today = new Date()
    var firstDay = new Date(today.getFullYear(), today.getMonth(), 1)
    
    startDateInput.text = Qt.formatDate(firstDay, "yyyy-MM-dd")
    endDateInput.text = Qt.formatDate(today, "yyyy-MM-dd")
}

function setDateRangeLastMonth() {
    var today = new Date()
    var firstDayLastMonth = new Date(today.getFullYear(), today.getMonth() - 1, 1)
    var lastDayLastMonth = new Date(today.getFullYear(), today.getMonth(), 0)
    
    startDateInput.text = Qt.formatDate(firstDayLastMonth, "yyyy-MM-dd")
    endDateInput.text = Qt.formatDate(lastDayLastMonth, "yyyy-MM-dd")
}

function setDateRangeAll() {
    startDateInput.text = "2020-01-01"
    endDateInput.text = Qt.formatDate(new Date(), "yyyy-MM-dd")
}
```

- [ ] **Step 3: 添加文件对话框和导出逻辑**

在 ExportDialog.qml 中添加：

```qml
FileDialog {
    id: fileDialog
    fileMode: FileDialog.SaveFile
    nameFilters: ["CSV files (*.csv)"]
    currentFolder: StandardPaths.standardLocations(StandardPaths.DocumentsLocation)[0]
    
    property string exportType: "all"
    property date startDate
    property date endDate
    
    onAccepted: {
        var filePath = selectedFile.toString().replace("file://", "")
        var result = false
        
        if (exportType === "tasks") {
            result = ExportService.exportTasks(startDate, endDate, filePath)
        } else if (exportType === "sessions") {
            result = ExportService.exportFocusSessions(startDate, endDate, filePath)
        }
        
        if (!result) {
            statusMessage.text = "导出失败，请检查文件路径权限"
        }
    }
}

FolderDialog {
    id: folderDialog
    currentFolder: StandardPaths.standardLocations(StandardPaths.DocumentsLocation)[0]
    
    property date startDate
    property date endDate
    
    onAccepted: {
        var dirPath = selectedFolder.toString().replace("file://", "")
        var result = ExportService.exportAll(startDate, endDate, dirPath)
        
        if (!result) {
            statusMessage.text = "导出失败，请检查目录权限"
        }
    }
}

function performExport() {
    var startDate = new Date(startDateInput.text)
    var endDate = new Date(endDateInput.text)
    
    if (startDate > endDate) {
        statusMessage.text = "开始日期不能晚于结束日期"
        return
    }
    
    statusMessage.text = ""
    
    if (exportAllRadio.checked) {
        folderDialog.startDate = startDate
        folderDialog.endDate = endDate
        folderDialog.open()
    } else if (exportTasksRadio.checked) {
        fileDialog.exportType = "tasks"
        fileDialog.startDate = startDate
        fileDialog.endDate = endDate
        fileDialog.currentFile = ExportService.generateFileName("tasks", startDate, endDate)
        fileDialog.open()
    } else if (exportSessionsRadio.checked) {
        fileDialog.exportType = "sessions"
        fileDialog.startDate = startDate
        fileDialog.endDate = endDate
        fileDialog.currentFile = ExportService.generateFileName("focus_sessions", startDate, endDate)
        fileDialog.open()
    }
}

Connections {
    target: ExportService
    
    function onExportCompleted(success, message) {
        if (success) {
            statusMessage.text = message
        } else {
            statusMessage.text = "错误: " + message
        }
    }
}
```

- [ ] **Step 4: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 5: 提交**

```bash
git add qml/components/ExportDialog.qml
git commit -m "feat: create ExportDialog with date range and content selection"
```

---

## Task 6: 在 Sidebar 添加数据导出入口

**Files:**
- Modify: `qml/components/Sidebar.qml`

- [ ] **Step 1: 在侧边栏添加数据导出按钮**

在 Sidebar.qml 中，在科目管理按钮下方添加：

```qml
Rectangle {
    width: parent.width - 20
    height: 40
    radius: 4
    color: exportMouseArea.containsMouse ? "#f5f3ed" : "transparent"
    anchors.horizontalCenter: parent.horizontalCenter
    
    Row {
        anchors.centerIn: parent
        spacing: 10
        
        Text {
            text: "📊"
            font.pixelSize: 18
            anchors.verticalCenter: parent.verticalCenter
        }
        
        Text {
            text: "数据导出"
            font.pixelSize: 14
            color: "#5d4e37"
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    
    MouseArea {
        id: exportMouseArea
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        
        onClicked: {
            exportDialog.open()
        }
    }
}
```

- [ ] **Step 2: 添加 ExportDialog 实例**

在 Sidebar 根元素内添加：

```qml
ExportDialog {
    id: exportDialog
    anchors.centerIn: Overlay.overlay
}
```

- [ ] **Step 3: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 4: 测试完整导出流程**

运行应用并测试：

```bash
cd build
./PomodoroTodo
```

测试步骤：
1. 点击侧边栏"数据导出"按钮
2. 测试快捷日期选择（本周、本月、上月、全部）
3. 选择"全部"导出类型，选择保存目录
4. 检查生成的两个 CSV 文件
5. 用文本编辑器或 Excel 打开 CSV 文件，验证：
   - UTF-8 编码正确（中文不乱码）
   - 字段名称正确
   - 数据内容完整
   - 科目信息正确关联
6. 测试"仅任务"和"仅专注记录"导出
7. 测试日期范围筛选是否准确

Expected: 所有功能正常，CSV 文件格式正确

- [ ] **Step 5: 提交**

```bash
git add qml/components/Sidebar.qml
git commit -m "feat: add data export entry in Sidebar"
```

---

## Task 7: 测试和优化

**Files:**
- Test: 所有数据导出相关功能

- [ ] **Step 1: CSV 格式验证测试**

测试清单：
- [ ] CSV 文件使用 UTF-8 编码
- [ ] 中文字符显示正确
- [ ] Excel 可以正确打开文件
- [ ] 逗号、引号、换行符正确转义
- [ ] 日期时间格式统一

创建测试任务：
- 任务标题包含逗号："复习,总结,归纳"
- 任务标题包含引号："学习"关键点"
- 任务标题包含换行符

Expected: 导出的 CSV 正确转义，Excel 打开无错乱

- [ ] **Step 2: 大数据量测试**

创建测试数据：
- 100+ 个任务
- 200+ 个专注记录

导出并验证：
- 导出速度合理（< 5秒）
- 内存占用正常
- 文件大小合理
- 进度信号正确触发

Expected: 大数据量导出正常

- [ ] **Step 3: 边界情况测试**

- [ ] 日期范围内无数据时导出空文件（仅包含表头）
- [ ] 开始日期晚于结束日期时显示错误提示
- [ ] 文件路径无写入权限时显示错误
- [ ] 未关联任务的专注记录显示"未关联任务"
- [ ] 未关联科目的任务显示"未分类"

- [ ] **Step 4: 错误处理测试**

测试场景：
- 选择只读目录导出
- 磁盘空间不足
- 数据库查询失败

Expected: 显示友好错误提示，不崩溃

- [ ] **Step 5: 性能优化（如有需要）**

如果导出速度慢：
- 检查数据库查询是否使用索引
- 考虑分批查询和写入
- 优化字符串拼接操作

- [ ] **Step 6: 创建测试文档**

在 `docs/testing/phase3-data-export-test.md` 创建测试报告：

```markdown
# Phase 3.2 数据导出功能测试报告

## 测试日期
[填写日期]

## 功能测试
- [x] 任务导出 CSV
- [x] 专注记录导出 CSV
- [x] 全部导出
- [x] 日期范围筛选
- [x] UTF-8 编码
- [x] 字段转义

## 性能测试
- 100条任务导出：< 1秒
- 200条专注记录导出：< 2秒

## 发现的问题
[列出问题]

## 结论
数据导出功能完整可用。
```

- [ ] **Step 7: 最终提交**

```bash
git add docs/testing/phase3-data-export-test.md
git commit -m "test: complete testing for data export functionality"
```

- [ ] **Step 8: 创建标签**

```bash
git tag -a v0.3.2 -m "Phase 3.2: Data export functionality"
```

---

## 完成检查清单

Phase 3.2 数据导出功能完成标准：

- [ ] 所有 7 个任务完成
- [ ] ExportService 服务功能完整
- [ ] exportTasks 方法正常工作
- [ ] exportFocusSessions 方法正常工作
- [ ] exportAll 方法正常工作
- [ ] CSV 文件使用 UTF-8 编码
- [ ] 特殊字符正确转义
- [ ] ExportDialog UI 可用且美观
- [ ] 日期范围选择功能正常
- [ ] 快捷日期按钮工作正常
- [ ] FileDialog 和 FolderDialog 正常弹出
- [ ] 导出进度反馈正确
- [ ] 错误提示友好明确
- [ ] 所有提交消息清晰
- [ ] 代码编译无警告
- [ ] 功能测试全部通过
- [ ] Excel 可以打开导出的 CSV
- [ ] 大数据量导出性能可接受

完成后可进入 Phase 3.3: 视觉动画优化实施。

