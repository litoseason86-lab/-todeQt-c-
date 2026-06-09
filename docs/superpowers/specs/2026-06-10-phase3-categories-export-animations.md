# Phase 3: 科目管理、数据导出和视觉优化设计文档

**版本**: 1.0  
**日期**: 2026-06-10  
**阶段**: 第三阶段优化

---

## 1. 项目概述

### 1.1 设计目标

在第二阶段功能基础上，完善应用的数据管理能力和用户体验：
- **科目管理系统**：支持预设和自定义科目，为统计提供更精确的分类
- **数据导出功能**：导出详细原始数据（任务和专注记录），用于备份和外部分析
- **视觉动画优化**：添加微妙自然的动画效果，提升应用流畅度和使用体验

### 1.2 实施策略

采用**数据优先底层重构**策略：
1. 先实现科目管理的数据库和服务层改造
2. 在稳定数据基础上实现导出功能
3. 最后添加视觉动画优化

### 1.3 设计原则

- **数据完整性优先**：确保数据库迁移不丢失现有数据
- **向后兼容**：保持与现有数据的兼容性
- **微妙自然**：动画效果不干扰用户，强调流畅过渡
- **性能优先**：CSV 导出支持大数据量，动画使用高效实现

---

## 2. 科目管理系统设计

## 3. 数据导出功能设计

## 4. 视觉动画优化设计

## 5. 技术架构

## 6. 数据库设计与迁移

## 7. 实施计划

---

## 2. 科目管理系统设计

### 2.1 功能需求

**预设科目**：
- 数学（#d4a574）
- 英语（#c9956e）
- 政治（#be8568）
- 专业课（#b37562）
- 其他（#a8655c）

**自定义科目**：
- 用户可以添加自定义科目
- 为每个科目设置名称和颜色
- 可以编辑和删除自定义科目（预设科目不可删除）

**科目使用**：
- 创建任务时选择科目
- 统计视图按科目分组展示数据
- 科目颜色用于视觉区分

### 2.2 数据库设计

**新增 categories 表**：
```sql
CREATE TABLE categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    color TEXT NOT NULL,           -- 十六进制颜色值
    is_preset BOOLEAN DEFAULT 0,   -- 是否为预设科目
    display_order INTEGER DEFAULT 0, -- 显示顺序
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

**修改 tasks 表**：
```sql
-- 新增字段
ALTER TABLE tasks ADD COLUMN category_id INTEGER REFERENCES categories(id);

-- 保留 category 文本字段用于向后兼容
-- category 字段不删除，作为备用
```

**初始化预设科目数据**：
```sql
INSERT INTO categories (name, color, is_preset, display_order) VALUES
('数学', '#d4a574', 1, 1),
('英语', '#c9956e', 1, 2),
('政治', '#be8568', 1, 3),
('专业课', '#b37562', 1, 4),
('其他', '#a8655c', 1, 5);
```

### 2.3 数据迁移策略

**迁移步骤**：
1. 创建 categories 表并插入预设科目
2. 扫描 tasks 表中现有的 category 文本值
3. 为每个唯一的 category 文本创建对应的自定义科目记录
4. 更新 tasks 表，将文本 category 映射到 category_id
5. 保留原 category 字段作为备用

**向后兼容规则**：
- 如果 category_id 存在，使用 category_id 查询科目信息
- 如果 category_id 为 NULL，回退到使用 category 文本字段
- 新任务必须设置 category_id

### 2.4 C++ 服务层

**新增 CategoryManager 单例服务**：

```cpp
class CategoryManager : public QObject {
    Q_OBJECT
public:
    static CategoryManager* instance();
    
    // 查询
    Q_INVOKABLE QVariantList getAllCategories();
    Q_INVOKABLE QVariantList getPresetCategories();
    Q_INVOKABLE QVariantList getCustomCategories();
    Q_INVOKABLE QVariantMap getCategoryById(int id);
    
    // 管理
    Q_INVOKABLE int addCategory(const QString& name, const QString& color);
    Q_INVOKABLE bool updateCategory(int id, const QString& name, const QString& color);
    Q_INVOKABLE bool deleteCategory(int id);
    
    // 校验
    Q_INVOKABLE bool canDeleteCategory(int id);  // 检查是否有关联任务
    
signals:
    void categoriesChanged();
};
```

**修改 TaskManager**：
```cpp
// 修改 addTask 方法
Q_INVOKABLE void addTask(const QString& title, 
                         const QDate& date, 
                         int categoryId);  // 改为使用 categoryId

// 查询方法返回包含完整科目信息
// 返回结构：{id, title, date, completed, category: {id, name, color}}
```

### 2.5 QML 界面

**CategoryDialog.qml**：
- 显示所有科目列表（预设 + 自定义）
- 预设科目显示为灰色不可编辑
- 自定义科目可编辑和删除
- 添加新科目按钮
- 颜色选择器（预设 8-10 种颜色）

**修改 AddTaskDialog**：
- 将科目输入框改为下拉选择
- 下拉列表显示科目名称和颜色标记
- 可快速选择现有科目

**修改任务显示**：
- TaskItem 显示科目颜色标签
- 使用科目的 color 属性渲染背景色

---

## 3. 数据导出功能设计

### 3.1 功能需求

**导出范围**：
- 导出详细原始数据（任务记录和专注会话）
- 支持日期范围筛选
- 包含完整的科目信息

**导出格式**：
- CSV 格式，UTF-8 编码
- Excel 和其他工具可直接打开
- 字段名称使用中文，便于阅读

**文件管理**：
- 用户选择保存位置
- 文件命名包含日期范围
- 支持导出任务和专注记录两个文件

### 3.2 CSV 格式定义

**任务导出（tasks.csv）**：
```csv
ID,标题,科目,日期,完成状态,创建时间
1,复习数据结构章节3,数学,2026-06-10,已完成,2026-06-09 08:30:00
2,背单词50个,英语,2026-06-10,未完成,2026-06-09 09:00:00
3,政治选择题练习,政治,2026-06-11,未完成,2026-06-10 10:15:00
```

**专注记录导出（focus_sessions.csv）**：
```csv
ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)
1,1,复习数据结构章节3,数学,2026-06-10 09:00:00,2026-06-10 10:30:00,90
2,2,背单词50个,英语,2026-06-10 14:00:00,2026-06-10 14:45:00,45
3,1,复习数据结构章节3,数学,2026-06-10 15:00:00,2026-06-10 16:20:00,80
```

**字段说明**：
- ID：记录的唯一标识符
- 完成状态：已完成/未完成
- 时长：分钟数，方便 Excel 中直接计算
- 科目：从 categories 表关联获取，未关联则显示"未分类"

### 3.3 C++ 服务层

**新增 ExportService 单例服务**：

```cpp
class ExportService : public QObject {
    Q_OBJECT
public:
    static ExportService* instance();
    
    // 导出方法
    Q_INVOKABLE bool exportTasks(const QDate& startDate, 
                                  const QDate& endDate, 
                                  const QString& filePath);
    
    Q_INVOKABLE bool exportFocusSessions(const QDate& startDate, 
                                         const QDate& endDate, 
                                         const QString& filePath);
    
    Q_INVOKABLE bool exportAll(const QDate& startDate, 
                               const QDate& endDate, 
                               const QString& dirPath);
    
    // 辅助方法
    Q_INVOKABLE QString generateFileName(const QString& type,
                                         const QDate& startDate,
                                         const QDate& endDate);
    
signals:
    void exportProgress(int current, int total);  // 导出进度
    void exportCompleted(bool success, const QString& message);
};
```

**实现细节**：
- 使用 QTextStream 生成 UTF-8 编码的 CSV
- 处理特殊字符（逗号、引号、换行）的转义
- 大数据量时分批查询，避免内存占用过高
- 导出过程中发送进度信号

**CSV 转义规则**：
```cpp
QString escapeCSVField(const QString& field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
        return QString("\"%1\"").arg(field.replace("\"", "\"\""));
    }
    return field;
}
```

### 3.4 QML 界面

**ExportDialog.qml**：
- 日期范围选择器（开始日期、结束日期）
- 默认值：当月（本月1日 - 今天）
- 快捷选项：本周、本月、上月、全部
- 导出内容选择：
  - 仅任务
  - 仅专注记录
  - 全部（推荐）
- 保存位置选择（使用 FileDialog）
- 导出按钮和进度提示

**文件命名规则**：
```
tasks_20260601_20260610.csv          # 任务导出
focus_sessions_20260601_20260610.csv # 专注记录导出
```

**集成位置**：
- 在侧边栏添加"数据导出"菜单项
- 或在设置页面添加"导出数据"按钮

### 3.5 错误处理

**可能的错误情况**：
- 文件路径无写入权限
- 磁盘空间不足
- 数据库查询失败
- 日期范围无效（开始日期晚于结束日期）

**错误提示**：
- 导出失败时显示具体错误信息
- 提供重试选项
- 记录错误日志到控制台

---

## 4. 视觉动画优化设计

### 4.1 动画设计原则

**微妙自然**：
- 动画时长控制在 150-300ms
- 使用柔和的缓动函数（Easing.OutQuad、Easing.InOutQuad）
- 不干扰用户注意力，强调流畅过渡
- 避免过度动画，保持简洁专业

**性能优先**：
- 使用 Animator 类型（在 render 线程运行）
- 避免 JavaScript 驱动的动画
- 减少重绘和重排
- 所有动画可通过全局设置统一控制

### 4.2 具体动画效果

#### 4.2.1 任务完成动画

**触发时机**：用户勾选任务的复选框

**动画效果**：
```qml
// 淡出 + 轻微下移
OpacityAnimator {
    target: taskItem
    from: 1.0
    to: 0.6
    duration: 200
    easing.type: Easing.OutQuad
}

NumberAnimation {
    target: taskItem
    property: "y"
    from: taskItem.y
    to: taskItem.y + 5
    duration: 200
    easing.type: Easing.OutQuad
}
```

**最终状态**：
- 任务项保持可见但变灰（opacity: 0.6）
- 文字添加删除线
- 不移除任务项，便于撤销操作

#### 4.2.2 页面切换过渡

**触发时机**：侧边栏导航切换视图

**动画效果**：
```qml
StackView {
    pushEnter: Transition {
        PropertyAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
    
    pushExit: Transition {
        PropertyAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: 150
            easing.type: Easing.InOutQuad
        }
    }
}
```

**视觉体验**：
- 旧页面淡出，新页面淡入
- 无位移动画，保持稳定
- 快速切换，不拖沓

#### 4.2.3 对话框动画

**触发时机**：AddTaskDialog、CategoryDialog、ExportDialog 打开和关闭

**打开动画**：
```qml
ParallelAnimation {
    NumberAnimation {
        target: dialog
        property: "scale"
        from: 0.95
        to: 1.0
        duration: 200
        easing.type: Easing.OutQuad
    }
    
    OpacityAnimator {
        target: dialog
        from: 0
        to: 1
        duration: 200
        easing.type: Easing.OutQuad
    }
}
```

**关闭动画**：
```qml
OpacityAnimator {
    target: dialog
    from: 1
    to: 0
    duration: 150
    easing.type: Easing.InQuad
}
```

**背景遮罩**：
- 半透明黑色背景（rgba(0,0,0,0.3)）
- 淡入淡出（150ms）

#### 4.2.4 列表项交互

**鼠标悬停效果**：
```qml
Behavior on color {
    ColorAnimation {
        duration: 100
        easing.type: Easing.InOutQuad
    }
}

// 悬停时背景色变化
color: mouseArea.containsMouse ? "#f5f3ed" : "#faf6ee"
```

**点击反馈**：
- 无额外动画
- 依赖系统默认的按钮按下状态
- 保持简洁

#### 4.2.5 统计卡片动画

**数字变化动画**：
```qml
Text {
    text: statisticsValue
    
    Behavior on text {
        NumberAnimation {
            duration: 300
            easing.type: Easing.OutQuad
        }
    }
}
```

**首次加载动画**：
```qml
// 统计卡片依次淡入（stagger effect）
Component.onCompleted: {
    fadeInAnimation.start()
}

SequentialAnimation {
    id: fadeInAnimation
    
    Repeater {
        model: statCards
        
        SequentialAnimation {
            PauseAnimation { duration: index * 50 }
            OpacityAnimator {
                target: modelData
                from: 0
                to: 1
                duration: 200
            }
        }
    }
}
```

### 4.3 实现方式

**使用声明式动画**：
```qml
// Behavior - 属性变化时自动触发
Behavior on opacity {
    OpacityAnimator { duration: 200 }
}

// Transition - 状态切换时触发
transitions: [
    Transition {
        from: "*"; to: "completed"
        ParallelAnimation {
            OpacityAnimator { duration: 200 }
            NumberAnimation { property: "y"; duration: 200 }
        }
    }
]
```

**避免性能问题**：
- 使用 Animator 类型（OpacityAnimator、ScaleAnimator）
- 避免在循环中创建动画对象
- 不对大列表中的所有项同时应用动画

**全局动画控制**：
```qml
// 预留设置项，允许用户禁用动画
readonly property bool animationsEnabled: true
readonly property int animationDuration: animationsEnabled ? 200 : 0
```

### 4.4 测试和调优

**性能测试**：
- 使用 Qt Creator 的 QML Profiler 检测动画性能
- 确保帧率保持在 60fps
- 测试低配置机器上的表现

**视觉测试**：
- 各动画效果是否自然流畅
- 动画时长是否合适（不过快或过慢）
- 多个动画叠加时是否协调

---

## 5. 技术架构

### 5.1 新增组件

**C++ 服务层**：
- `CategoryManager` - 科目管理服务
- `ExportService` - 数据导出服务

**QML 组件**：
- `CategoryDialog.qml` - 科目管理对话框
- `ExportDialog.qml` - 数据导出对话框
- `ColorPicker.qml` - 颜色选择器组件

### 5.2 修改组件

**C++ 服务层**：
- `DatabaseManager` - 添加数据库版本管理和迁移机制
- `TaskManager` - 支持 categoryId，返回完整科目信息
- `StatisticsService` - 使用新的科目关联查询

**QML 组件**：
- `AddTaskDialog.qml` - 科目输入框改为下拉选择
- `TaskItem.qml` - 显示科目颜色标签
- `MainWindow.qml` - 添加动画过渡效果
- 所有视图 - 添加微妙的进入/退出动画

### 5.3 组件交互流程

**科目管理流程**：
```
用户打开 CategoryDialog
    ↓
显示所有科目（CategoryManager.getAllCategories()）
    ↓
用户添加/编辑/删除科目
    ↓
CategoryManager 更新数据库
    ↓
发送 categoriesChanged() 信号
    ↓
所有使用科目的组件自动刷新
```

**数据导出流程**：
```
用户打开 ExportDialog
    ↓
选择日期范围和导出内容
    ↓
点击导出按钮，选择保存位置
    ↓
ExportService.exportAll(startDate, endDate, dirPath)
    ↓
生成 CSV 文件，发送进度信号
    ↓
完成后显示成功提示和文件位置
```

### 5.4 依赖关系

```
QML 层
  ├── MainWindow
  │   ├── Sidebar (添加科目管理和导出入口)
  │   └── StackView (各视图，添加动画)
  ├── CategoryDialog → CategoryManager
  ├── ExportDialog → ExportService
  └── AddTaskDialog → CategoryManager, TaskManager

C++ 服务层
  ├── CategoryManager → DatabaseManager
  ├── ExportService → DatabaseManager
  └── TaskManager → DatabaseManager, CategoryManager
```

---

## 6. 数据库设计与迁移

### 6.1 数据库版本管理

**版本追踪**：
```cpp
// 使用 SQLite PRAGMA user_version
void DatabaseManager::initDatabase() {
    int currentVersion = getDatabaseVersion();
    
    if (currentVersion == 0) {
        // 初始化数据库（创建所有表）
        createInitialSchema();
        setDatabaseVersion(2);  // 第三阶段直接设为版本2
    } else if (currentVersion == 1) {
        // 从版本1迁移到版本2
        migrateToVersion2();
    }
}

int DatabaseManager::getDatabaseVersion() {
    QSqlQuery query("PRAGMA user_version");
    if (query.next()) {
        return query.value(0).toInt();
    }
    return 0;
}

void DatabaseManager::setDatabaseVersion(int version) {
    QSqlQuery query;
    query.prepare("PRAGMA user_version = ?");
    query.addBindValue(version);
    query.exec();
}
```

### 6.2 迁移到版本 2

**迁移步骤**：
```cpp
void DatabaseManager::migrateToVersion2() {
    QSqlDatabase db = database();
    db.transaction();
    
    try {
        // 1. 创建 categories 表
        createCategoriesTable();
        
        // 2. 插入预设科目
        insertPresetCategories();
        
        // 3. 迁移现有任务的科目数据
        migrateTaskCategories();
        
        // 4. 添加 category_id 字段到 tasks 表
        alterTasksTable();
        
        // 5. 更新版本号
        setDatabaseVersion(2);
        
        db.commit();
        qInfo() << "Database migrated to version 2 successfully";
        
    } catch (const std::exception& e) {
        db.rollback();
        qCritical() << "Migration failed:" << e.what();
        throw;
    }
}
```

**迁移任务科目数据**：
```cpp
void DatabaseManager::migrateTaskCategories() {
    // 获取所有唯一的 category 文本值
    QSqlQuery query("SELECT DISTINCT category FROM tasks WHERE category IS NOT NULL AND category != ''");
    
    QStringList existingCategories;
    while (query.next()) {
        existingCategories << query.value(0).toString();
    }
    
    // 为每个唯一的 category 创建自定义科目
    for (const QString& categoryName : existingCategories) {
        // 检查是否已存在（可能与预设科目重名）
        if (!categoryExists(categoryName)) {
            // 创建自定义科目
            addCustomCategory(categoryName, generateColor());
        }
        
        // 更新 tasks 表，设置 category_id
        updateTaskCategoryId(categoryName);
    }
}
```

### 6.3 数据完整性保证

**事务处理**：
- 所有数据库迁移操作在事务中执行
- 失败时自动回滚，不破坏现有数据

**备份策略**：
- 迁移前自动创建数据库备份文件
- 备份文件命名：`pomodoro_backup_YYYYMMDD_HHMMSS.db`
- 保留最近 3 个备份文件

**错误处理**：
- 迁移失败时显示友好错误提示
- 提供恢复选项（从备份恢复）
- 记录详细错误日志

### 6.4 完整数据库 Schema（版本 2）

```sql
-- tasks 表
CREATE TABLE tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    category TEXT,                      -- 保留用于向后兼容
    category_id INTEGER,                -- 新增：关联 categories 表
    date DATE NOT NULL,
    completed BOOLEAN DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (category_id) REFERENCES categories(id)
);

CREATE INDEX idx_tasks_date ON tasks(date);
CREATE INDEX idx_tasks_completed ON tasks(completed);
CREATE INDEX idx_tasks_category_id ON tasks(category_id);

-- focus_sessions 表（无变化）
CREATE TABLE focus_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP,
    duration INTEGER,
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);

CREATE INDEX idx_sessions_task ON focus_sessions(task_id);
CREATE INDEX idx_sessions_start ON focus_sessions(start_time);

-- categories 表（新增）
CREATE TABLE categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    color TEXT NOT NULL,
    is_preset BOOLEAN DEFAULT 0,
    display_order INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_categories_display_order ON categories(display_order);
```

---

## 7. 实施计划

### 7.1 阶段划分

#### 阶段 1：科目管理基础（优先级：高）

**目标**：完成数据库迁移和科目管理核心功能

**任务清单**：
1. 数据库版本管理机制
   - 实现 getDatabaseVersion/setDatabaseVersion
   - 创建备份功能
   
2. 数据库迁移
   - 创建 categories 表
   - 插入预设科目数据
   - 迁移现有任务的 category 字段
   - 添加 category_id 字段

3. CategoryManager 服务
   - 实现查询方法（getAllCategories 等）
   - 实现管理方法（add/update/delete）
   - 实现信号通知机制

4. 修改 TaskManager
   - addTask 方法支持 categoryId
   - 查询方法返回完整科目信息

5. CategoryDialog UI
   - 科目列表展示
   - 添加/编辑/删除科目
   - 颜色选择器

6. 修改 AddTaskDialog
   - 科目下拉选择器
   - 集成 CategoryManager

**预计时间**：3-4天

#### 阶段 2：数据导出功能（优先级：中）

**目标**：实现完整的数据导出功能

**任务清单**：
1. ExportService 服务
   - 实现 CSV 生成逻辑
   - 实现字段转义处理
   - 实现进度通知

2. exportTasks 方法
   - 查询任务数据
   - 生成 CSV 文件

3. exportFocusSessions 方法
   - 查询专注记录
   - 关联任务和科目信息
   - 生成 CSV 文件

4. ExportDialog UI
   - 日期范围选择
   - 导出内容选择
   - 文件保存对话框
   - 进度显示

5. 集成到主界面
   - 在侧边栏或设置页添加入口
   - 测试导出功能

**预计时间**：2-3天

#### 阶段 3：视觉动画优化（优先级：低）

**目标**：提升应用的视觉体验和流畅度

**任务清单**：
1. 任务完成动画
   - 实现淡出 + 下移效果
   - 添加删除线样式

2. 页面切换动画
   - StackView 过渡效果
   - 淡入淡出实现

3. 对话框动画
   - 打开/关闭动画
   - 背景遮罩淡入淡出

4. 列表项交互
   - 悬停效果
   - 颜色过渡动画

5. 统计卡片动画
   - 数字变化动画
   - 首次加载 stagger 效果

6. 全局动画控制
   - 添加动画开关设置（预留）
   - 性能测试和优化

**预计时间**：2天

### 7.2 总体时间线

- **阶段 1（科目管理）**：第 1-4 天
- **阶段 2（数据导出）**：第 5-7 天
- **阶段 3（视觉动画）**：第 8-9 天
- **集成测试和修复**：第 10 天

**总计**：约 10 天完成第三阶段所有功能

### 7.3 测试策略

#### 功能测试

**科目管理**：
- 预设科目正确显示
- 添加自定义科目
- 编辑和删除自定义科目
- 删除有关联任务的科目时提示错误
- 任务创建时科目关联正确

**数据迁移**：
- 现有任务的科目数据正确迁移
- category_id 正确关联
- 向后兼容性测试（旧数据能正常读取）

**数据导出**：
- 导出的 CSV 格式正确
- UTF-8 编码正确（中文不乱码）
- 日期范围筛选准确
- 特殊字符正确转义
- 大数据量导出不崩溃

**视觉动画**：
- 所有动画流畅运行（60fps）
- 动画时长合适
- 多个动画叠加时协调
- 低配置机器上性能可接受

#### 性能测试

**数据库性能**：
- 大量任务（1000+）时查询速度
- 科目关联查询性能

**导出性能**：
- 导出 1000+ 条记录的耗时
- 内存占用情况

**动画性能**：
- 使用 QML Profiler 检测帧率
- 动画期间 CPU 占用

#### 兼容性测试

**平台测试**：
- macOS 测试
- Windows 测试（如有条件）

**数据兼容性**：
- 从版本 1 升级到版本 2
- 旧版本数据能正常使用

### 7.4 风险和应对

**风险 1：数据库迁移失败**
- 应对：事务保护 + 自动备份
- 失败时提供从备份恢复选项

**风险 2：导出大数据量时内存溢出**
- 应对：分批查询和写入
- 限制单次导出的记录数量上限

**风险 3：动画性能影响用户体验**
- 应对：使用 Animator 类型，优化动画实现
- 提供动画开关，允许用户禁用

**风险 4：科目颜色冲突**
- 应对：预设 8-10 种不同的颜色
- 用户自定义时提供颜色预览

---

## 8. 总结

第三阶段将在第二阶段的基础上，完善应用的数据管理能力和用户体验：

1. **科目管理系统**：提供预设和自定义科目，数据库迁移保证数据完整性
2. **数据导出功能**：导出详细原始数据为 CSV 格式，便于备份和分析
3. **视觉动画优化**：添加微妙自然的动画效果，提升应用流畅度

**技术亮点**：
- 数据库版本管理和自动迁移机制
- 事务保护和自动备份策略
- UTF-8 CSV 导出，正确处理特殊字符
- 高性能动画实现，使用 Animator 类型

**用户价值**：
- 更精确的学习数据分类和统计
- 数据导出支持外部分析和长期备份
- 更流畅自然的操作体验

完成第三阶段后，番茄Todo 将成为一个功能完整、体验优秀的考研专注管理应用。

