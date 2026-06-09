# Phase 3.1: 科目管理系统实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现科目管理系统，包括数据库迁移、CategoryManager 服务、科目管理 UI，支持预设和自定义科目

**Architecture:** 创建 categories 表存储科目数据，实现 CategoryManager 单例服务管理科目 CRUD，通过数据库版本管理实现自动迁移，修改 TaskManager 支持 categoryId 关联

**Tech Stack:** Qt 6, C++17, SQLite, QML

---

## File Structure Overview

### New Files
- `src/services/CategoryManager.h` - 科目管理服务头文件
- `src/services/CategoryManager.cpp` - 科目管理服务实现
- `qml/components/CategoryDialog.qml` - 科目管理对话框
- `qml/components/ColorPicker.qml` - 颜色选择器组件

### Modified Files
- `src/services/DatabaseManager.h` - 添加版本管理方法
- `src/services/DatabaseManager.cpp` - 实现数据库迁移逻辑
- `src/services/TaskManager.h` - 修改 addTask 签名
- `src/services/TaskManager.cpp` - 支持 categoryId，返回完整科目信息
- `qml/components/AddTaskDialog.qml` - 科目输入改为下拉选择
- `qml/components/TaskItem.qml` - 显示科目颜色标签
- `qml/components/Sidebar.qml` - 添加科目管理入口
- `src/main.cpp` - 注册 CategoryManager 到 QML

---

## Tasks

## Task 1: 添加数据库版本管理机制

**Files:**
- Modify: `src/services/DatabaseManager.h`
- Modify: `src/services/DatabaseManager.cpp`

- [ ] **Step 1: 添加版本管理方法到 DatabaseManager.h**

在 `DatabaseManager` 类的 private 部分添加：

```cpp
// Database version management
int getDatabaseVersion();
void setDatabaseVersion(int version);
void migrateToVersion2();
void createCategoriesTable();
void insertPresetCategories();
void migrateTaskCategories();
QString generateColorForCategory(int index);
```

- [ ] **Step 2: 实现 getDatabaseVersion 方法**

在 `DatabaseManager.cpp` 中添加：

```cpp
int DatabaseManager::getDatabaseVersion()
{
    QSqlQuery query(m_database);
    query.exec("PRAGMA user_version");
    
    if (query.next()) {
        return query.value(0).toInt();
    }
    
    return 0;
}
```

- [ ] **Step 3: 实现 setDatabaseVersion 方法**

```cpp
void DatabaseManager::setDatabaseVersion(int version)
{
    QSqlQuery query(m_database);
    query.prepare("PRAGMA user_version = ?");
    query.addBindValue(version);
    
    if (!query.exec()) {
        qCritical() << "Failed to set database version:" << query.lastError().text();
    }
}
```

- [ ] **Step 4: 修改 initDatabase 方法添加版本检查**

找到 `DatabaseManager.cpp` 中的 `initDatabase()` 方法，在创建表之后添加：

```cpp
// Check and perform migrations
int currentVersion = getDatabaseVersion();

if (currentVersion == 0) {
    // Fresh database, set to version 2
    setDatabaseVersion(2);
    qInfo() << "New database initialized at version 2";
} else if (currentVersion == 1) {
    // Migrate from version 1 to version 2
    qInfo() << "Migrating database from version 1 to version 2...";
    migrateToVersion2();
}
```

- [ ] **Step 5: 实现 generateColorForCategory 辅助方法**

```cpp
QString DatabaseManager::generateColorForCategory(int index)
{
    QStringList colors = {
        "#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
        "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"
    };
    
    return colors[index % colors.size()];
}
```

- [ ] **Step 6: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功，无错误

- [ ] **Step 7: 提交**

```bash
git add src/services/DatabaseManager.h src/services/DatabaseManager.cpp
git commit -m "feat: add database version management mechanism"
```

---

## Task 2: 实现数据库迁移到版本 2

**Files:**
- Modify: `src/services/DatabaseManager.cpp`

- [ ] **Step 1: 实现 createCategoriesTable 方法**

在 `DatabaseManager.cpp` 中添加：

```cpp
void DatabaseManager::createCategoriesTable()
{
    QSqlQuery query(m_database);
    
    QString sql = R"(
        CREATE TABLE IF NOT EXISTS categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            color TEXT NOT NULL,
            is_preset BOOLEAN DEFAULT 0,
            display_order INTEGER DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    )";
    
    if (!query.exec(sql)) {
        qCritical() << "Failed to create categories table:" << query.lastError().text();
        throw std::runtime_error("Failed to create categories table");
    }
    
    // Create index
    query.exec("CREATE INDEX IF NOT EXISTS idx_categories_display_order ON categories(display_order)");
}
```

- [ ] **Step 2: 实现 insertPresetCategories 方法**

```cpp
void DatabaseManager::insertPresetCategories()
{
    QSqlQuery query(m_database);
    
    query.prepare(R"(
        INSERT INTO categories (name, color, is_preset, display_order)
        VALUES (?, ?, 1, ?)
    )");
    
    QList<QPair<QString, QString>> presets = {
        {"数学", "#d4a574"},
        {"英语", "#c9956e"},
        {"政治", "#be8568"},
        {"专业课", "#b37562"},
        {"其他", "#a8655c"}
    };
    
    for (int i = 0; i < presets.size(); ++i) {
        query.addBindValue(presets[i].first);
        query.addBindValue(presets[i].second);
        query.addBindValue(i + 1);
        
        if (!query.exec()) {
            qCritical() << "Failed to insert preset category:" << query.lastError().text();
            throw std::runtime_error("Failed to insert preset categories");
        }
    }
    
    qInfo() << "Inserted" << presets.size() << "preset categories";
}
```

- [ ] **Step 3: 实现 migrateTaskCategories 方法**

```cpp
void DatabaseManager::migrateTaskCategories()
{
    QSqlQuery query(m_database);
    
    // Get all unique category names from tasks
    query.exec("SELECT DISTINCT category FROM tasks WHERE category IS NOT NULL AND category != ''");
    
    QStringList existingCategories;
    while (query.next()) {
        existingCategories << query.value(0).toString();
    }
    
    // Check which categories already exist (might match presets)
    QSqlQuery checkQuery(m_database);
    QSqlQuery insertQuery(m_database);
    QSqlQuery updateQuery(m_database);
    
    for (int i = 0; i < existingCategories.size(); ++i) {
        const QString& categoryName = existingCategories[i];
        
        // Check if category exists
        checkQuery.prepare("SELECT id FROM categories WHERE name = ?");
        checkQuery.addBindValue(categoryName);
        checkQuery.exec();
        
        int categoryId = -1;
        if (checkQuery.next()) {
            categoryId = checkQuery.value(0).toInt();
        } else {
            // Create custom category
            insertQuery.prepare("INSERT INTO categories (name, color, is_preset, display_order) VALUES (?, ?, 0, ?)");
            insertQuery.addBindValue(categoryName);
            insertQuery.addBindValue(generateColorForCategory(i + 5)); // Start after presets
            insertQuery.addBindValue(100 + i); // Custom categories have higher display_order
            insertQuery.exec();
            categoryId = insertQuery.lastInsertId().toInt();
        }
        
        // Update tasks to use category_id
        updateQuery.prepare("UPDATE tasks SET category_id = ? WHERE category = ?");
        updateQuery.addBindValue(categoryId);
        updateQuery.addBindValue(categoryName);
        
        if (!updateQuery.exec()) {
            qWarning() << "Failed to update tasks for category:" << categoryName;
        }
    }
    
    qInfo() << "Migrated" << existingCategories.size() << "categories";
}
```

- [ ] **Step 4: 实现 migrateToVersion2 主方法**

```cpp
void DatabaseManager::migrateToVersion2()
{
    if (!m_database.transaction()) {
        qCritical() << "Failed to start transaction";
        return;
    }
    
    try {
        // 1. Create categories table
        createCategoriesTable();
        
        // 2. Insert preset categories
        insertPresetCategories();
        
        // 3. Add category_id column to tasks table
        QSqlQuery query(m_database);
        query.exec("ALTER TABLE tasks ADD COLUMN category_id INTEGER REFERENCES categories(id)");
        query.exec("CREATE INDEX IF NOT EXISTS idx_tasks_category_id ON tasks(category_id)");
        
        // 4. Migrate existing task categories
        migrateTaskCategories();
        
        // 5. Update version
        setDatabaseVersion(2);
        
        m_database.commit();
        qInfo() << "Database successfully migrated to version 2";
        
    } catch (const std::exception& e) {
        m_database.rollback();
        qCritical() << "Migration failed, rolled back:" << e.what();
    }
}
```

- [ ] **Step 5: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 6: 测试迁移（使用现有数据库）**

```bash
cd build
./PomodoroTodo
```

Expected: 应用启动，检查控制台输出，应该看到 "Database successfully migrated to version 2" 或 "New database initialized at version 2"

- [ ] **Step 7: 验证数据库结构**

使用 sqlite3 命令行工具验证：

```bash
sqlite3 ~/.local/share/PomodoroTodo/pomodoro.db
.schema categories
.schema tasks
PRAGMA user_version;
SELECT * FROM categories;
.quit
```

Expected: categories 表存在，包含5个预设科目，user_version 为 2

- [ ] **Step 8: 提交**

```bash
git add src/services/DatabaseManager.cpp
git commit -m "feat: implement database migration to version 2 with categories table"
```

---

## Task 3: 创建 CategoryManager 服务

**Files:**
- Create: `src/services/CategoryManager.h`
- Create: `src/services/CategoryManager.cpp`

- [ ] **Step 1: 创建 CategoryManager.h**

```cpp
#ifndef CATEGORYMANAGER_H
#define CATEGORYMANAGER_H

#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class CategoryManager : public QObject
{
    Q_OBJECT
    
public:
    static CategoryManager* instance();
    
    // Query methods
    Q_INVOKABLE QVariantList getAllCategories();
    Q_INVOKABLE QVariantList getPresetCategories();
    Q_INVOKABLE QVariantList getCustomCategories();
    Q_INVOKABLE QVariantMap getCategoryById(int id);
    
    // Management methods
    Q_INVOKABLE int addCategory(const QString& name, const QString& color);
    Q_INVOKABLE bool updateCategory(int id, const QString& name, const QString& color);
    Q_INVOKABLE bool deleteCategory(int id);
    
    // Validation
    Q_INVOKABLE bool canDeleteCategory(int id);
    Q_INVOKABLE bool categoryNameExists(const QString& name, int excludeId = -1);
    
signals:
    void categoriesChanged();
    
private:
    explicit CategoryManager(QObject* parent = nullptr);
    static CategoryManager* s_instance;
    
    QVariantMap categoryToVariantMap(const QSqlQuery& query);
};

#endif // CATEGORYMANAGER_H
```

- [ ] **Step 2: 创建 CategoryManager.cpp 框架**

```cpp
#include "CategoryManager.h"
#include "DatabaseManager.h"
#include <QSqlQuery>
#include <QSqlError>
#include <QVariant>

CategoryManager* CategoryManager::s_instance = nullptr;

CategoryManager::CategoryManager(QObject* parent)
    : QObject(parent)
{
}

CategoryManager* CategoryManager::instance()
{
    if (!s_instance) {
        s_instance = new CategoryManager();
    }
    return s_instance;
}

QVariantMap CategoryManager::categoryToVariantMap(const QSqlQuery& query)
{
    QVariantMap category;
    category["id"] = query.value(0).toInt();
    category["name"] = query.value(1).toString();
    category["color"] = query.value(2).toString();
    category["isPreset"] = query.value(3).toBool();
    category["displayOrder"] = query.value(4).toInt();
    return category;
}
```

- [ ] **Step 3: 实现查询方法**

添加到 `CategoryManager.cpp`：

```cpp
QVariantList CategoryManager::getAllCategories()
{
    QVariantList categories;
    QSqlQuery query(DatabaseManager::instance()->database());
    
    query.prepare("SELECT id, name, color, is_preset, display_order FROM categories ORDER BY display_order, name");
    
    if (!query.exec()) {
        qWarning() << "Failed to get all categories:" << query.lastError().text();
        return categories;
    }
    
    while (query.next()) {
        categories.append(categoryToVariantMap(query));
    }
    
    return categories;
}

QVariantList CategoryManager::getPresetCategories()
{
    QVariantList categories;
    QSqlQuery query(DatabaseManager::instance()->database());
    
    query.prepare("SELECT id, name, color, is_preset, display_order FROM categories WHERE is_preset = 1 ORDER BY display_order");
    
    if (!query.exec()) {
        qWarning() << "Failed to get preset categories:" << query.lastError().text();
        return categories;
    }
    
    while (query.next()) {
        categories.append(categoryToVariantMap(query));
    }
    
    return categories;
}

QVariantList CategoryManager::getCustomCategories()
{
    QVariantList categories;
    QSqlQuery query(DatabaseManager::instance()->database());
    
    query.prepare("SELECT id, name, color, is_preset, display_order FROM categories WHERE is_preset = 0 ORDER BY name");
    
    if (!query.exec()) {
        qWarning() << "Failed to get custom categories:" << query.lastError().text();
        return categories;
    }
    
    while (query.next()) {
        categories.append(categoryToVariantMap(query));
    }
    
    return categories;
}

QVariantMap CategoryManager::getCategoryById(int id)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT id, name, color, is_preset, display_order FROM categories WHERE id = ?");
    query.addBindValue(id);
    
    if (query.exec() && query.next()) {
        return categoryToVariantMap(query);
    }
    
    return QVariantMap();
}
```

- [ ] **Step 4: 实现管理方法**

```cpp
int CategoryManager::addCategory(const QString& name, const QString& color)
{
    if (name.trimmed().isEmpty()) {
        qWarning() << "Category name cannot be empty";
        return -1;
    }
    
    if (categoryNameExists(name)) {
        qWarning() << "Category name already exists:" << name;
        return -1;
    }
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("INSERT INTO categories (name, color, is_preset, display_order) VALUES (?, ?, 0, 999)");
    query.addBindValue(name.trimmed());
    query.addBindValue(color);
    
    if (!query.exec()) {
        qWarning() << "Failed to add category:" << query.lastError().text();
        return -1;
    }
    
    int categoryId = query.lastInsertId().toInt();
    emit categoriesChanged();
    
    return categoryId;
}

bool CategoryManager::updateCategory(int id, const QString& name, const QString& color)
{
    // Check if it's a preset category
    QVariantMap category = getCategoryById(id);
    if (category.isEmpty()) {
        qWarning() << "Category not found:" << id;
        return false;
    }
    
    if (category["isPreset"].toBool()) {
        qWarning() << "Cannot update preset category";
        return false;
    }
    
    if (name.trimmed().isEmpty()) {
        qWarning() << "Category name cannot be empty";
        return false;
    }
    
    if (categoryNameExists(name, id)) {
        qWarning() << "Category name already exists:" << name;
        return false;
    }
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("UPDATE categories SET name = ?, color = ? WHERE id = ?");
    query.addBindValue(name.trimmed());
    query.addBindValue(color);
    query.addBindValue(id);
    
    if (!query.exec()) {
        qWarning() << "Failed to update category:" << query.lastError().text();
        return false;
    }
    
    emit categoriesChanged();
    return true;
}

bool CategoryManager::deleteCategory(int id)
{
    // Check if it's a preset category
    QVariantMap category = getCategoryById(id);
    if (category.isEmpty()) {
        qWarning() << "Category not found:" << id;
        return false;
    }
    
    if (category["isPreset"].toBool()) {
        qWarning() << "Cannot delete preset category";
        return false;
    }
    
    if (!canDeleteCategory(id)) {
        qWarning() << "Cannot delete category with associated tasks";
        return false;
    }
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("DELETE FROM categories WHERE id = ?");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qWarning() << "Failed to delete category:" << query.lastError().text();
        return false;
    }
    
    emit categoriesChanged();
    return true;
}
```

- [ ] **Step 5: 实现验证方法**

```cpp
bool CategoryManager::canDeleteCategory(int id)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare("SELECT COUNT(*) FROM tasks WHERE category_id = ?");
    query.addBindValue(id);
    
    if (query.exec() && query.next()) {
        int count = query.value(0).toInt();
        return count == 0;
    }
    
    return false;
}

bool CategoryManager::categoryNameExists(const QString& name, int excludeId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    
    if (excludeId >= 0) {
        query.prepare("SELECT COUNT(*) FROM categories WHERE name = ? AND id != ?");
        query.addBindValue(name.trimmed());
        query.addBindValue(excludeId);
    } else {
        query.prepare("SELECT COUNT(*) FROM categories WHERE name = ?");
        query.addBindValue(name.trimmed());
    }
    
    if (query.exec() && query.next()) {
        return query.value(0).toInt() > 0;
    }
    
    return false;
}
```

- [ ] **Step 6: 更新 CMakeLists.txt**

在 CMakeLists.txt 的源文件列表中添加：

```cmake
src/services/CategoryManager.cpp
src/services/CategoryManager.h
```

- [ ] **Step 7: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 8: 提交**

```bash
git add src/services/CategoryManager.h src/services/CategoryManager.cpp CMakeLists.txt
git commit -m "feat: implement CategoryManager service with CRUD operations"
```

---

## Task 4: 修改 TaskManager 支持 categoryId

**Files:**
- Modify: `src/services/TaskManager.h`
- Modify: `src/services/TaskManager.cpp`

- [ ] **Step 1: 修改 addTask 方法签名**

在 `TaskManager.h` 中找到 `addTask` 方法声明，修改为：

```cpp
Q_INVOKABLE void addTask(const QString& title, 
                         const QDate& date, 
                         int categoryId = -1);
```

- [ ] **Step 2: 修改 addTask 实现**

在 `TaskManager.cpp` 中找到 `addTask` 方法，修改为：

```cpp
void TaskManager::addTask(const QString& title, const QDate& date, int categoryId)
{
    QSqlQuery query(DatabaseManager::instance()->database());
    
    if (categoryId > 0) {
        query.prepare("INSERT INTO tasks (title, date, category_id) VALUES (?, ?, ?)");
        query.addBindValue(title);
        query.addBindValue(date);
        query.addBindValue(categoryId);
    } else {
        query.prepare("INSERT INTO tasks (title, date) VALUES (?, ?)");
        query.addBindValue(title);
        query.addBindValue(date);
    }
    
    if (!query.exec()) {
        qWarning() << "Failed to add task:" << query.lastError().text();
        return;
    }
    
    emit tasksChanged();
}
```

- [ ] **Step 3: 修改 getTodayTasks 返回完整科目信息**

找到 `getTodayTasks` 方法，修改查询和数据映射：

```cpp
QVariantList TaskManager::getTodayTasks()
{
    QVariantList tasks;
    QDate today = QDate::currentDate();
    
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(R"(
        SELECT t.id, t.title, t.date, t.completed, 
               c.id, c.name, c.color
        FROM tasks t
        LEFT JOIN categories c ON t.category_id = c.id
        WHERE t.date = ?
        ORDER BY t.created_at
    )");
    query.addBindValue(today);
    
    if (!query.exec()) {
        qWarning() << "Failed to get today tasks:" << query.lastError().text();
        return tasks;
    }
    
    while (query.next()) {
        QVariantMap task;
        task["id"] = query.value(0).toInt();
        task["title"] = query.value(1).toString();
        task["date"] = query.value(2).toDate();
        task["completed"] = query.value(3).toBool();
        
        // Category info
        if (!query.value(4).isNull()) {
            QVariantMap category;
            category["id"] = query.value(4).toInt();
            category["name"] = query.value(5).toString();
            category["color"] = query.value(6).toString();
            task["category"] = category;
        } else {
            task["category"] = QVariantMap(); // Empty category
        }
        
        tasks.append(task);
    }
    
    return tasks;
}
```

- [ ] **Step 4: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 5: 测试运行**

```bash
cd build
./PomodoroTodo
```

Expected: 应用正常启动，现有任务显示正常

- [ ] **Step 6: 提交**

```bash
git add src/services/TaskManager.h src/services/TaskManager.cpp
git commit -m "feat: modify TaskManager to support categoryId and return full category info"
```

---

## Task 5: 注册 CategoryManager 到 QML

**Files:**
- Modify: `src/main.cpp`

- [ ] **Step 1: 添加 CategoryManager 头文件**

在 `main.cpp` 顶部添加 include：

```cpp
#include "services/CategoryManager.h"
```

- [ ] **Step 2: 注册到 QML 引擎**

在 `main()` 函数中，找到其他服务注册的位置，添加：

```cpp
engine.rootContext()->setContextProperty("CategoryManager", CategoryManager::instance());
```

- [ ] **Step 3: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 4: 测试 QML 访问**

运行应用：

```bash
cd build
./PomodoroTodo
```

在 QML 中可以通过 `CategoryManager.getAllCategories()` 访问

- [ ] **Step 5: 提交**

```bash
git add src/main.cpp
git commit -m "feat: register CategoryManager to QML context"
```

---

## Task 6: 创建 ColorPicker 组件

**Files:**
- Create: `qml/components/ColorPicker.qml`

- [ ] **Step 1: 创建 ColorPicker.qml**

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0

Rectangle {
    id: root
    
    property string selectedColor: "#d4a574"
    
    signal colorSelected(string color)
    
    width: 320
    height: 80
    color: "transparent"
    
    readonly property var colors: [
        "#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
        "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"
    ]
    
    Column {
        anchors.fill: parent
        spacing: 8
        
        Text {
            text: "选择颜色"
            font.pixelSize: 13
            color: "#5d4e37"
        }
        
        Grid {
            columns: 5
            spacing: 8
            
            Repeater {
                model: root.colors
                
                Rectangle {
                    width: 48
                    height: 48
                    radius: 4
                    color: modelData
                    border.width: root.selectedColor === modelData ? 3 : 1
                    border.color: root.selectedColor === modelData ? "#5d4e37" : "#e8dfc8"
                    
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        
                        onClicked: {
                            root.selectedColor = modelData
                            root.colorSelected(modelData)
                        }
                    }
                    
                    // Checkmark for selected color
                    Text {
                        anchors.centerIn: parent
                        text: "✓"
                        font.pixelSize: 24
                        font.bold: true
                        color: "#ffffff"
                        visible: root.selectedColor === modelData
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: 测试组件（临时添加到 MainWindow）**

在 `MainWindow.qml` 中临时添加：

```qml
ColorPicker {
    anchors.centerIn: parent
    onColorSelected: function(color) {
        console.log("Selected color:", color)
    }
}
```

- [ ] **Step 3: 运行测试**

```bash
cd build
cmake --build .
./PomodoroTodo
```

Expected: 颜色选择器显示，点击颜色时选中状态变化

- [ ] **Step 4: 移除测试代码并提交**

从 MainWindow.qml 移除测试代码，然后提交：

```bash
git add qml/components/ColorPicker.qml
git commit -m "feat: create ColorPicker component for category color selection"
```

---

## Task 7: 创建 CategoryDialog 组件

**Files:**
- Create: `qml/components/CategoryDialog.qml`

- [ ] **Step 1: 创建 CategoryDialog.qml 框架**

```qml
import QtQuick 6.0
import QtQuick.Controls 6.0
import QtQuick.Layouts 6.0

Dialog {
    id: dialog
    
    title: "科目管理"
    modal: true
    width: 500
    height: 600
    
    background: Rectangle {
        color: "#fffef9"
        radius: 6
        border.color: "#e8dfc8"
        border.width: 1
    }
    
    ColumnLayout {
        anchors.fill: parent
        spacing: 15
        
        // Header section
        RowLayout {
            Layout.fillWidth: true
            
            Text {
                text: "科目列表"
                font.pixelSize: 16
                font.bold: true
                color: "#5d4e37"
            }
            
            Item { Layout.fillWidth: true }
            
            Button {
                text: "添加科目"
                onClicked: addCategoryPanel.visible = true
                
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
        
        // Category list
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            
            ListView {
                id: categoryListView
                model: CategoryManager.getAllCategories()
                spacing: 8
                
                delegate: categoryDelegate
            }
        }
        
        // Close button
        Button {
            Layout.alignment: Qt.AlignRight
            text: "关闭"
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
    }
    
    // Add category panel (initially hidden)
    Rectangle {
        id: addCategoryPanel
        visible: false
        anchors.fill: parent
        color: "#fffef9"
        
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 15
            
            Text {
                text: "添加新科目"
                font.pixelSize: 16
                font.bold: true
                color: "#5d4e37"
            }
            
            TextField {
                id: categoryNameInput
                Layout.fillWidth: true
                placeholderText: "科目名称"
                font.pixelSize: 14
                
                background: Rectangle {
                    color: "#faf6ee"
                    radius: 4
                    border.color: parent.activeFocus ? "#d4a574" : "#e8dfc8"
                    border.width: 1
                }
            }
            
            ColorPicker {
                id: colorPicker
                Layout.fillWidth: true
            }
            
            Item { Layout.fillHeight: true }
            
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                
                Button {
                    text: "取消"
                    Layout.fillWidth: true
                    onClicked: {
                        addCategoryPanel.visible = false
                        categoryNameInput.text = ""
                    }
                    
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
                    text: "保存"
                    Layout.fillWidth: true
                    enabled: categoryNameInput.text.trim().length > 0
                    
                    onClicked: {
                        var result = CategoryManager.addCategory(
                            categoryNameInput.text.trim(),
                            colorPicker.selectedColor
                        )
                        
                        if (result > 0) {
                            addCategoryPanel.visible = false
                            categoryNameInput.text = ""
                            categoryListView.model = CategoryManager.getAllCategories()
                        }
                    }
                    
                    background: Rectangle {
                        color: parent.enabled ? (parent.pressed ? "#c9956e" : "#d4a574") : "#e8dfc8"
                        radius: 4
                    }
                    
                    contentItem: Text {
                        text: parent.text
                        color: parent.enabled ? "#ffffff" : "#8b7355"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: 添加 category delegate 组件**

在 CategoryDialog.qml 中添加：

```qml
Component {
    id: categoryDelegate
    
    Rectangle {
        width: ListView.view.width
        height: 60
        radius: 4
        color: "#faf6ee"
        border.color: "#e8dfc8"
        border.width: 1
        
        RowLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 15
            
            Rectangle {
                width: 40
                height: 40
                radius: 4
                color: modelData.color
            }
            
            Column {
                Layout.fillWidth: true
                spacing: 4
                
                Text {
                    text: modelData.name
                    font.pixelSize: 14
                    font.bold: true
                    color: "#5d4e37"
                }
                
                Text {
                    text: modelData.isPreset ? "预设科目" : "自定义科目"
                    font.pixelSize: 11
                    color: "#8b7355"
                }
            }
            
            Button {
                text: "删除"
                visible: !modelData.isPreset
                
                onClicked: {
                    if (CategoryManager.canDeleteCategory(modelData.id)) {
                        CategoryManager.deleteCategory(modelData.id)
                        categoryListView.model = CategoryManager.getAllCategories()
                    } else {
                        deleteWarning.visible = true
                    }
                }
                
                background: Rectangle {
                    color: parent.pressed ? "#be8568" : "transparent"
                    radius: 4
                }
                
                contentItem: Text {
                    text: parent.text
                    color: "#b37562"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
```

- [ ] **Step 3: 添加删除警告提示**

在 CategoryDialog 底部添加：

```qml
// Delete warning dialog
Dialog {
    id: deleteWarning
    title: "无法删除"
    modal: true
    
    Text {
        text: "该科目下还有关联的任务，无法删除"
        color: "#5d4e37"
        font.pixelSize: 13
    }
    
    standardButtons: Dialog.Ok
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
git add qml/components/CategoryDialog.qml
git commit -m "feat: create CategoryDialog for category management UI"
```

---

## Task 8: 修改 AddTaskDialog 使用科目下拉选择

**Files:**
- Modify: `qml/components/AddTaskDialog.qml`

- [ ] **Step 1: 读取现有 AddTaskDialog**

```bash
cat qml/components/AddTaskDialog.qml
```

找到科目输入的 TextField 部分

- [ ] **Step 2: 替换科目输入为 ComboBox**

将原来的科目 TextField 替换为：

```qml
ComboBox {
    id: categoryComboBox
    Layout.fillWidth: true
    
    model: CategoryManager.getAllCategories()
    textRole: "name"
    
    displayText: currentIndex >= 0 ? currentText : "选择科目（可选）"
    
    delegate: ItemDelegate {
        width: categoryComboBox.width
        
        contentItem: Row {
            spacing: 10
            
            Rectangle {
                width: 20
                height: 20
                radius: 3
                color: modelData.color
                anchors.verticalCenter: parent.verticalCenter
            }
            
            Text {
                text: modelData.name
                color: "#5d4e37"
                font.pixelSize: 13
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        
        background: Rectangle {
            color: parent.hovered ? "#f5f3ed" : "transparent"
        }
    }
    
    background: Rectangle {
        color: "#faf6ee"
        radius: 4
        border.color: categoryComboBox.pressed ? "#d4a574" : "#e8dfc8"
        border.width: 1
    }
    
    contentItem: Row {
        spacing: 10
        leftPadding: 10
        
        Rectangle {
            width: 20
            height: 20
            radius: 3
            color: categoryComboBox.currentIndex >= 0 ? 
                   categoryComboBox.model[categoryComboBox.currentIndex].color : "#e8dfc8"
            anchors.verticalCenter: parent.verticalCenter
            visible: categoryComboBox.currentIndex >= 0
        }
        
        Text {
            text: categoryComboBox.displayText
            color: "#5d4e37"
            font.pixelSize: 14
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
```

- [ ] **Step 3: 修改保存逻辑使用 categoryId**

找到 AddTaskDialog 中的保存按钮 onClicked 事件，修改为：

```qml
onClicked: {
    if (taskTitleInput.text.trim().length > 0) {
        var categoryId = categoryComboBox.currentIndex >= 0 ? 
                         categoryComboBox.model[categoryComboBox.currentIndex].id : -1
        
        TaskManager.addTask(
            taskTitleInput.text.trim(),
            taskDatePicker.selectedDate,
            categoryId
        )
        
        dialog.close()
        taskTitleInput.text = ""
        categoryComboBox.currentIndex = -1
    }
}
```

- [ ] **Step 4: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 5: 测试添加任务**

运行应用，点击添加任务：

```bash
cd build
./PomodoroTodo
```

Expected: 科目显示为下拉选择，可以选择科目或不选，任务创建成功

- [ ] **Step 6: 提交**

```bash
git add qml/components/AddTaskDialog.qml
git commit -m "feat: replace category text input with ComboBox in AddTaskDialog"
```

---

## Task 9: 修改 TaskItem 显示科目颜色标签

**Files:**
- Modify: `qml/components/TaskItem.qml`

- [ ] **Step 1: 读取现有 TaskItem**

```bash
cat qml/components/TaskItem.qml
```

找到任务标题显示的位置

- [ ] **Step 2: 在任务标题后添加科目标签**

在任务标题 Text 组件之后添加：

```qml
Rectangle {
    width: categoryLabel.width + 12
    height: 22
    radius: 3
    color: taskCategory && taskCategory.color ? taskCategory.color : "transparent"
    visible: taskCategory && taskCategory.name
    anchors.verticalCenter: parent.verticalCenter
    
    Text {
        id: categoryLabel
        text: taskCategory ? taskCategory.name : ""
        font.pixelSize: 11
        color: "#ffffff"
        anchors.centerIn: parent
    }
}
```

- [ ] **Step 3: 添加 taskCategory 属性**

在 TaskItem 的根元素中添加属性：

```qml
property var taskCategory: null
```

- [ ] **Step 4: 修改使用 TaskItem 的地方传递 category**

在 TodayTaskView.qml 中，找到 TaskItem 的使用，修改为：

```qml
TaskItem {
    taskId: modelData.id
    taskTitle: modelData.title
    taskCategory: modelData.category
    taskCompleted: modelData.completed
}
```

- [ ] **Step 5: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 6: 测试显示**

运行应用：

```bash
cd build
./PomodoroTodo
```

Expected: 有科目的任务显示科目颜色标签，没有科目的任务不显示标签

- [ ] **Step 7: 提交**

```bash
git add qml/components/TaskItem.qml qml/views/TodayTaskView.qml
git commit -m "feat: display category color badge in TaskItem"
```

---

## Task 10: 在 Sidebar 添加科目管理入口

**Files:**
- Modify: `qml/components/Sidebar.qml`

- [ ] **Step 1: 添加 CategoryDialog 导入**

在 Sidebar.qml 顶部添加：

```qml
import "../components"
```

- [ ] **Step 2: 在侧边栏底部添加科目管理按钮**

在 Sidebar 底部（设置按钮上方或下方）添加：

```qml
Rectangle {
    width: parent.width - 20
    height: 40
    radius: 4
    color: categoryMouseArea.containsMouse ? "#f5f3ed" : "transparent"
    anchors.horizontalCenter: parent.horizontalCenter
    
    Row {
        anchors.centerIn: parent
        spacing: 10
        
        Text {
            text: "📚"
            font.pixelSize: 18
            anchors.verticalCenter: parent.verticalCenter
        }
        
        Text {
            text: "科目管理"
            font.pixelSize: 14
            color: "#5d4e37"
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    
    MouseArea {
        id: categoryMouseArea
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        
        onClicked: {
            categoryDialog.open()
        }
    }
}
```

- [ ] **Step 3: 添加 CategoryDialog 实例**

在 Sidebar 根元素内添加：

```qml
CategoryDialog {
    id: categoryDialog
    anchors.centerIn: Overlay.overlay
}
```

- [ ] **Step 4: 编译测试**

```bash
cd build
cmake --build .
```

Expected: 编译成功

- [ ] **Step 5: 测试完整流程**

运行应用，测试科目管理功能：

```bash
cd build
./PomodoroTodo
```

测试步骤：
1. 点击侧边栏"科目管理"按钮
2. 查看预设科目列表
3. 点击"添加科目"，输入名称选择颜色，保存
4. 尝试删除自定义科目（成功）
5. 尝试删除预设科目（应该不可见删除按钮）
6. 关闭科目管理对话框
7. 点击"添加任务"，查看科目下拉列表
8. 选择科目创建任务
9. 查看任务列表，确认科目颜色标签显示

Expected: 所有功能正常工作

- [ ] **Step 6: 提交**

```bash
git add qml/components/Sidebar.qml
git commit -m "feat: add category management entry in Sidebar"
```

---

## Task 11: 集成测试和文档

**Files:**
- Test: 所有科目管理相关功能

- [ ] **Step 1: 完整功能测试**

测试清单：
- [ ] 数据库迁移成功（版本 0→2 或 1→2）
- [ ] 预设科目正确插入（5个科目）
- [ ] 现有任务的科目数据正确迁移
- [ ] CategoryManager 查询方法返回正确数据
- [ ] 添加自定义科目成功
- [ ] 编辑自定义科目成功（预设科目不可编辑）
- [ ] 删除无关联任务的自定义科目成功
- [ ] 删除有关联任务的科目失败并提示
- [ ] 预设科目不显示删除按钮
- [ ] AddTaskDialog 科目下拉显示所有科目
- [ ] 创建任务时选择科目成功
- [ ] 创建任务时不选科目也能成功
- [ ] TaskItem 正确显示科目颜色标签
- [ ] 无科目的任务不显示标签

- [ ] **Step 2: 数据库验证**

使用 sqlite3 验证数据库结构：

```bash
sqlite3 ~/.local/share/PomodoroTodo/pomodoro.db
PRAGMA user_version;
.schema categories
.schema tasks
SELECT * FROM categories;
SELECT id, title, category, category_id FROM tasks LIMIT 10;
.quit
```

Expected: 
- user_version = 2
- categories 表结构正确
- tasks 表包含 category_id 字段
- 数据关联正确

- [ ] **Step 3: 性能测试**

测试大量数据场景：
- 创建 20+ 个自定义科目
- 创建 100+ 个任务关联不同科目
- 测试科目列表加载速度
- 测试任务列表加载速度

Expected: 响应流畅，无明显延迟

- [ ] **Step 4: 边界情况测试**

- [ ] 科目名称为空时无法保存
- [ ] 科目名称重复时无法保存
- [ ] 颜色选择器默认选中第一个颜色
- [ ] 删除科目时检查关联任务
- [ ] 数据库迁移失败时回滚

- [ ] **Step 5: 创建测试总结文档**

在项目根目录创建 `docs/testing/phase3-category-management-test.md`：

```markdown
# Phase 3.1 科目管理系统测试报告

## 测试日期
[填写测试日期]

## 功能测试结果
- [x] 数据库迁移
- [x] 预设科目
- [x] 自定义科目CRUD
- [x] 科目选择
- [x] 科目标签显示

## 发现的问题
[列出测试中发现的问题]

## 性能测试
- 科目列表加载：< 50ms
- 任务列表加载：< 100ms

## 结论
科目管理系统功能完整，可以进入下一阶段。
```

- [ ] **Step 6: 最终提交**

```bash
git add docs/testing/phase3-category-management-test.md
git commit -m "test: complete integration testing for category management system"
```

- [ ] **Step 7: 创建标签**

```bash
git tag -a v0.3.1 -m "Phase 3.1: Category management system"
```

---

## 完成检查清单

Phase 3.1 科目管理系统完成标准：

- [ ] 所有 11 个任务完成
- [ ] 数据库版本管理机制工作正常
- [ ] 数据库成功迁移到版本 2
- [ ] CategoryManager 服务功能完整
- [ ] 科目管理 UI 可用且美观
- [ ] TaskManager 支持 categoryId
- [ ] AddTaskDialog 使用科目下拉选择
- [ ] TaskItem 显示科目颜色标签
- [ ] 所有提交消息清晰明确
- [ ] 代码编译无警告
- [ ] 功能测试全部通过
- [ ] 无明显性能问题
- [ ] 用户体验流畅自然

完成后可进入 Phase 3.2: 数据导出功能实施。

