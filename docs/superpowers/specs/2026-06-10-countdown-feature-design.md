# 目标倒计时功能设计文档

## 1. 概述

### 1.1 功能描述
为番茄Todo应用添加目标倒计时功能，帮助用户追踪重要日期（如研究生初试考试）。支持多个倒计时目标管理，并在两个位置展示：
- **独立视图页**：完整的目标列表管理界面
- **今日任务页顶部**：首选目标的倒计时横幅

### 1.2 用户场景
- 用户添加"研究生初试 - 2026-12-23"等目标
- 每天打开应用时，在今日任务页顶部看到"距离研究生初试还有195天"
- 点击横幅或侧边栏"目标倒计时"入口，进入完整列表管理所有目标
- 通过拖拽排序调整目标优先级，首选目标自动显示在横幅中

### 1.3 设计原则
- 与现有架构保持一致（C++ Service + QML View模式）
- 遵循温暖纸质主题的视觉风格
- 数据持久化到SQLite，保证可靠性
- UI简洁直观，操作流畅

---

## 2. 架构设计

### 2.1 技术栈
- **数据层**：C++17 + Qt 6 + SQLite
- **UI层**：Qt Quick/QML
- **测试**：Qt Test

### 2.2 模块划分

**数据层 (C++)**
- `CountdownGoal` 结构体 - 目标数据模型
- `CountdownService` 类 - 业务逻辑和数据持久化
- `CountdownModel` 类 - QAbstractListModel实现

**UI层 (QML)**
- `CountdownView.qml` - 独立视图页
- `CountdownBanner.qml` - 横幅组件（今日任务页顶部）
- `CountdownItem.qml` - 列表项组件
- `CountdownDialog.qml` - 添加/编辑对话框

**集成点**
- `Sidebar.qml` - 添加"目标倒计时"入口
- `MainWindow.qml` - 注册CountdownView到视图栈
- `TodayTaskView.qml` - 集成CountdownBanner
- `main.cpp` - 初始化CountdownService

### 2.3 数据流
```
用户操作 → CountdownDialog → CountdownService → SQLite
                                      ↓
                            CountdownModel (QML绑定)
                                      ↓
                     CountdownView / CountdownBanner (UI更新)
```

---

## 3. 数据模型设计

### 3.1 数据库表结构

```sql
CREATE TABLE countdown_goals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    target_date TEXT NOT NULL,  -- ISO 8601格式 "YYYY-MM-DD"
    display_order INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX idx_display_order ON countdown_goals(display_order);
```

### 3.2 C++数据结构

```cpp
struct CountdownGoal {
    int id;
    QString name;
    QDate targetDate;
    int displayOrder;
    QDateTime createdAt;
    QDateTime updatedAt;
    
    // 计算剩余天数（正数=未来，负数=已过期）
    int daysRemaining() const;
};
```

### 3.3 CountdownService接口

```cpp
class CountdownService : public QObject {
    Q_OBJECT
    Q_PROPERTY(CountdownModel* model READ model CONSTANT)
    Q_PROPERTY(CountdownGoal* primaryGoal READ primaryGoal NOTIFY primaryGoalChanged)
    
public:
    explicit CountdownService(QObject *parent = nullptr);
    
    // CRUD操作
    Q_INVOKABLE bool addGoal(const QString &name, const QDate &targetDate);
    Q_INVOKABLE bool updateGoal(int id, const QString &name, const QDate &targetDate);
    Q_INVOKABLE bool deleteGoal(int id);
    Q_INVOKABLE bool reorder(int fromIndex, int toIndex);
    
    // 工具方法
    Q_INVOKABLE int calculateDaysRemaining(const QDate &targetDate) const;
    
    CountdownModel* model() const { return m_model; }
    CountdownGoal* primaryGoal() const { return m_primaryGoal; }
    
signals:
    void primaryGoalChanged();
    void errorOccurred(const QString &message);
    
private:
    void loadGoals();
    void updatePrimaryGoal();
    
    CountdownModel *m_model;
    CountdownGoal *m_primaryGoal;
    QSqlDatabase m_database;
};
```

### 3.4 CountdownModel接口

```cpp
class CountdownModel : public QAbstractListModel {
    Q_OBJECT
    
public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NameRole,
        TargetDateRole,
        DisplayOrderRole,
        DaysRemainingRole
    };
    
    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;
    
    void setGoals(const QList<CountdownGoal> &goals);
    void addGoal(const CountdownGoal &goal);
    void updateGoal(int index, const CountdownGoal &goal);
    void removeGoal(int index);
    void moveGoal(int fromIndex, int toIndex);
};
```

---

## 4. UI组件设计

### 4.1 CountdownBanner.qml（今日任务页横幅）

**位置**：TodayTaskView顶部，任务列表之前

**布局**：
- 全宽，高度60px
- 左侧：目标名称（15px Medium）+ 目标日期（11px Normal）
- 右侧：天数（32px Bold）+ "天"文字（11px Normal）

**样式**：
- 背景：渐变 `linear-gradient(90deg, #f0e6d2, #faf6ee)`
- 左边框：3px solid `#d4a574`
- 圆角：6px
- 内边距：12px 20px

**交互**：
- 点击跳转到CountdownView
- 悬停效果：轻微缩放(1.01)

**空状态**：
- 无首选目标时显示"+ 添加目标倒计时"
- 点击打开CountdownDialog

### 4.2 CountdownView.qml（独立视图页）

**布局结构**：
```
┌─────────────────────────────────┐
│  目标倒计时          [ + ]      │  ← 标题栏
├─────────────────────────────────┤
│  ┌───────────────────────────┐  │
│  │   📚 研究生初试           │  │  ← 首选目标大卡片
│  │        195               │  │     (居中，64px天数)
│  │         天               │  │
│  │   2026年12月23日         │  │
│  └───────────────────────────┘  │
├─────────────────────────────────┤
│  ≡  💼 毕业答辩      87天       │  ← 次要目标列表
│  ≡  🎯 托福考试      45天       │     (紧凑，20px天数)
└─────────────────────────────────┘
```

**首选目标卡片**：
- 背景：渐变 `linear-gradient(135deg, #f0e6d2, #faf6ee)`
- 边框：2px solid `#d4a574`
- 内边距：32px
- 天数字号：64px Bold，颜色`#d4a574`
- 点击编辑

**次要目标列表**：
- 使用ListView + CountdownItem delegate
- 支持拖拽排序（长按"≡"图标）
- 列表项间距：12px

**空状态**：
- 居中显示"暂无目标倒计时"
- 下方显示"点击右上角 + 添加第一个目标"

### 4.3 CountdownItem.qml（次要目标列表项）

**布局**：
- 左侧：拖拽手柄"≡" + 目标名称
- 右侧：天数 + "天"

**样式**：
- 背景：`#faf8f3`
- 圆角：6px
- 内边距：12px 16px
- 高度：自适应（最小48px）

**交互**：
- 点击：打开编辑对话框
- 右滑：显示删除按钮
- 长按"≡"：进入拖拽模式

### 4.4 CountdownDialog.qml（添加/编辑对话框）

**字段**：
1. 目标名称：TextField（占位符"例如：研究生初试"）
2. 目标日期：DatePicker（默认今天+30天）

**按钮**：
- 取消：关闭对话框
- 确定：保存并关闭

**验证**：
- 名称：1-50字符，非空
- 日期：有效日期（可以是过去或未来）

**样式**：
- 复用AddTaskDialog的温暖纸质主题
- 对话框宽度：480px
- 内边距：24px

---

## 5. 交互流程设计

### 5.1 添加目标
1. 用户点击CountdownView右上角"+"或CountdownBanner空状态
2. 弹出CountdownDialog
3. 输入目标名称、选择目标日期
4. 点击"确定" → CountdownService.addGoal()
5. 新目标插入到列表末尾，自动分配displayOrder
6. UI自动刷新，若是第一个目标则成为首选目标

### 5.2 编辑目标
1. 用户点击CountdownItem或首选目标卡片
2. 弹出CountdownDialog（预填充数据）
3. 修改名称或日期
4. 点击"确定" → CountdownService.updateGoal()
5. UI自动刷新

### 5.3 删除目标
1. 用户在CountdownItem上右滑
2. 显示删除按钮
3. 点击确认 → CountdownService.deleteGoal()
4. 若删除的是首选目标，第二个目标自动提升
5. UI自动刷新

### 5.4 拖拽排序
1. 用户长按CountdownItem的"≡"图标
2. 拖动到新位置
3. ListView显示拖拽动画
4. 松手 → CountdownService.reorder(fromIndex, toIndex)
5. 更新displayOrder字段
6. primaryGoal自动切换为新的第一项
7. CountdownBanner实时更新

### 5.5 天数计算
- 公式：`目标日期 - 当前日期`
- 未来日期：显示"195天"
- 当天：显示"0天"
- 已过期：显示"已过期 5天"

---

## 6. 视图集成设计

### 6.1 Sidebar.qml修改
在"数据统计"项后添加：
```qml
SidebarItem {
    text: "目标倒计时"
    marker: "⏰"
    isActive: root.currentView === "countdown"
    onClicked: root.itemClicked("countdown")
}
```

### 6.2 MainWindow.qml修改
1. StackLayout添加CountdownView（索引5）
2. viewIndex()函数添加分支：
```qml
case "countdown":
    return 5;
```
3. 传递countdownService引用

### 6.3 TodayTaskView.qml修改
在ColumnLayout顶部插入：
```qml
CountdownBanner {
    Layout.fillWidth: true
    Layout.bottomMargin: 16
    primaryGoal: countdownService.primaryGoal
    onClicked: mainWindow.switchToView("countdown")
    visible: countdownService.primaryGoal !== null
}
```

### 6.4 main.cpp修改
1. 创建CountdownService实例：
```cpp
CountdownService countdownService;
```
2. 注册到QML上下文：
```cpp
engine.rootContext()->setContextProperty("countdownService", &countdownService);
```

### 6.5 CMakeLists.txt修改
添加新文件：
- `src/services/CountdownService.h`
- `src/services/CountdownService.cpp`
- `src/models/CountdownModel.h`
- `src/models/CountdownModel.cpp`
- `qml/views/CountdownView.qml`
- `qml/components/CountdownBanner.qml`
- `qml/components/CountdownItem.qml`
- `qml/components/CountdownDialog.qml`

---

## 7. 错误处理与边界情况

### 7.1 数据库错误
- **初始化失败**：应用启动时检查表是否存在，不存在则创建
- **写入失败**：emit errorOccurred信号，QML显示Toast提示
- **读取失败**：返回空列表，记录qWarning日志

### 7.2 输入验证
- **目标名称**：1-50字符，去除首尾空格，非空
- **目标日期**：有效QDate对象，可以是过去或未来
- **重复名称**：允许（用户可能有多个同名目标）

### 7.3 边界情况
- **无目标**：CountdownView显示空状态，CountdownBanner隐藏
- **单个目标**：仅显示大卡片，不显示列表区域
- **所有目标已过期**：正常显示负数天数"已过期 N天"
- **拖拽到同一位置**：不触发reorder操作
- **删除首选目标**：自动提升displayOrder次小的目标

### 7.4 性能考虑
- **天数计算**：不缓存，每次渲染时实时计算（QDate::daysTo()开销小）
- **列表渲染**：使用ListView的delegate缓存机制
- **数据库操作**：启动时一次性加载到内存，后续操作同步更新内存+异步写入数据库

---

## 8. 测试策略

### 8.1 单元测试（Qt Test）

**CountdownServiceTest**
- `testAddGoal()` - 添加目标，验证数据库插入
- `testUpdateGoal()` - 更新目标，验证字段修改
- `testDeleteGoal()` - 删除目标，验证数据库清理
- `testReorder()` - 拖拽排序，验证displayOrder更新
- `testPrimaryGoal()` - 验证首选目标始终是displayOrder最小的
- `testCalculateDaysRemaining()` - 验证天数计算（正数、负数、当天）
- `testDeletePrimaryGoal()` - 删除首选目标后，验证新的首选目标

**CountdownModelTest**
- `testRowCount()` - 验证列表数量正确
- `testData()` - 验证各数据角色返回值
- `testAddGoal()` - 添加后验证beginInsertRows/endInsertRows
- `testRemoveGoal()` - 删除后验证beginRemoveRows/endRemoveRows
- `testMoveGoal()` - 移动后验证beginMoveRows/endMoveRows

### 8.2 集成测试
- 启动应用 → 验证CountdownView可从侧边栏访问
- 添加第一个目标 → 验证TodayTaskView横幅显示
- 添加第二个目标 → 验证CountdownView显示大卡片+列表
- 拖拽排序 → 验证横幅实时更新为新首选目标
- 删除所有目标 → 验证空状态显示

### 8.3 手动测试清单
- [ ] CountdownBanner点击跳转到CountdownView
- [ ] CountdownView右上角"+"按钮打开对话框
- [ ] 添加目标后列表实时更新
- [ ] 编辑目标后数据正确更新
- [ ] 右滑删除目标流畅
- [ ] 拖拽排序动画自然，首选目标自动切换
- [ ] 过期目标显示"已过期 N天"
- [ ] 视图切换动画正常
- [ ] 应用重启后数据持久化正确

---

## 9. 实施计划

### 阶段1：数据层
1. 创建CountdownGoal结构体
2. 实现CountdownService（数据库操作）
3. 实现CountdownModel（QAbstractListModel）
4. 编写单元测试

### 阶段2：UI组件
1. 创建CountdownDialog（添加/编辑对话框）
2. 创建CountdownItem（列表项组件）
3. 创建CountdownBanner（横幅组件）
4. 创建CountdownView（独立视图页）

### 阶段3：集成
1. 修改Sidebar添加入口
2. 修改MainWindow注册视图
3. 修改TodayTaskView集成横幅
4. 修改main.cpp初始化服务

### 阶段4：测试与优化
1. 运行单元测试
2. 手动测试所有交互流程
3. 性能优化（如有必要）
4. 文档更新

---

## 10. 未来扩展

### 10.1 可选功能（暂不实施）
- 目标分类/标签（学习、工作、生活）
- 目标完成提醒通知
- 倒计时进度百分比（基于起始日期）
- 目标历史记录（已完成/已过期目标归档）
- 导出倒计时数据

### 10.2 技术债务
- 无

---

## 11. 总结

本设计文档定义了目标倒计时功能的完整实现方案，包括：
- **架构设计**：C++ Service + QML View模式，与现有代码一致
- **数据模型**：SQLite持久化，支持CRUD和排序
- **UI设计**：混合布局（大卡片+列表），两处展示（独立视图+今日任务横幅）
- **交互设计**：拖拽排序、内联编辑、实时计算
- **测试策略**：单元测试 + 集成测试 + 手动测试

设计遵循YAGNI原则，专注于核心功能，为用户提供简洁高效的目标倒计时体验。
