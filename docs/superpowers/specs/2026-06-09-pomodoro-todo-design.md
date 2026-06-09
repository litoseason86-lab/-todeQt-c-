# 番茄Todo - 考研专注管理应用设计文档

**版本**: 1.0  
**日期**: 2026-06-09  
**目标用户**: 计算机研究生考试备考者

---

## 1. 项目概述

### 1.1 项目目标

为考研学生开发一款Qt/C++桌面应用，结合任务管理和专注统计功能，帮助高效完成复习计划并追踪学习状态。

### 1.2 核心用户场景

1. **长期规划**：按时间维度组织任务（今日、本周、月度）
2. **日常执行**：从任务列表启动专注计时，自动关联任务和时长
3. **数据分析**：查看今日和本周的专注时长、任务完成率等关键指标

### 1.3 设计原则

- **简单优先**：任务只有"未完成/已完成"两种状态，避免过度复杂
- **专注统计为核心**：重点记录和展示学习时长，而非严格的番茄钟提醒
- **视觉舒适**：温暖纸感风格，适合长时间使用
- **本地优先**：所有数据存储在本地，无需云同步

---

## 2. 界面设计

### 2.1 主界面布局

采用**侧边栏 + 主内容区**的经典布局：

#### 左侧边栏（约200px宽）
- **时间视图导航**
  - 今日任务
  - 本周计划
  - 月度目标
- **功能入口**
  - 数据统计
  - 设置

#### 主内容区
- 根据侧边栏选择动态切换内容
- 主要展示任务列表或统计图表

### 2.2 核心页面

#### 2.2.1 今日任务页
**功能**：
- 显示今天的所有任务列表
- 任务项组成：
  - 复选框（标记完成）
  - 任务标题
  - 科目标签（可选）
  - "开始专注"按钮

**交互**：
- 勾选复选框：任务标记为完成，显示打勾动画
- 点击"开始专注"：跳转到专注页，开始计时
- 快捷键支持：Enter键快速添加新任务

#### 2.2.2 专注页（独立页面）
**设计目标**：提供沉浸式专注体验，减少干扰

**显示内容**：
- 当前任务名称（大字号显示）
- 科目标签
- 计时器（显示已专注时间，格式：HH:MM:SS）
- 控制按钮：
  - 暂停/继续
  - 结束专注

**交互流程**：
1. 从任务页点击"开始专注"进入
2. 计时器每秒更新
3. 点击"结束专注"后：
   - 保存专注记录到数据库
   - 自动返回任务列表页

**视觉设计**：
- 背景色稍深或使用柔和渐变，营造专注氛围
- 大字号计时器居中显示
- 按钮布局简洁明了

#### 2.2.3 本周计划页
**功能**：
- 展示本周（周一到周日）的任务分布
- 可以查看每天有哪些任务
- 支持为未来几天添加任务

**展示形式**：
- 按日期分组的任务列表
- 或使用周视图日历形式

#### 2.2.4 月度目标页
**功能**：
- 更宏观的任务视图
- 可以规划整个月的学习安排
- 查看月度整体进度

#### 2.2.5 数据统计页
**统计维度**：

1. **今日数据**
   - 总专注时长（大字号突出显示）
   - 已完成任务数 / 总任务数
   - 完成率百分比

2. **本周趋势**
   - 柱状图：展示周一到周日每天的专注时长
   - 趋势分析：本周总时长、日均时长

3. **科目分配**
   - 饼图：各科目专注时长占比
   - 列表：每个科目的详细时长

4. **任务完成率**
   - 本周任务完成情况
   - 完成率趋势

### 2.3 视觉风格

#### 温暖纸感主题

**色彩系统**：
```
背景色：      #fffef9  (米白)
侧边栏：      #faf8f3  (浅米黄)
卡片背景：    #faf6ee  (纸质感)
边框色：      #e8dfc8  (淡棕)
主文字：      #5d4e37  (深棕)
次要文字：    #8b7355  (中棕)
强调色：      #d4a574  (暖橙)
```

**排版规范**：
- 字体：系统默认字体（macOS使用苹方）
- 标题：16-18px
- 正文：14px
- 次要信息：12px
- 圆角：4-6px（柔和感）
- 阴影：`0 1px 3px rgba(0,0,0,0.05)`（淡淡的柔和阴影）

**设计特点**：
- 模拟纸质笔记本质感
- 柔和的色调，长时间使用不刺眼
- 适量的留白和阴影，营造温馨舒适的氛围

---

## 3. 技术架构

### 3.1 技术栈

- **UI框架**：Qt Quick/QML - 实现流畅动画和现代化界面
- **后端逻辑**：C++ - 处理业务逻辑和数据管理
- **数据存储**：SQLite - 本地数据库，无需云同步
- **构建系统**：CMake

### 3.2 架构模式

采用**单例服务 + QML直连**架构：

```
┌─────────────────────────────────────┐
│          QML 界面层                  │
│  (Views, Components)                │
└──────────────┬──────────────────────┘
               │ 直接调用
               ↓
┌─────────────────────────────────────┐
│       C++ 单例服务层                 │
│  ┌──────────────────────────────┐   │
│  │  TaskManager                 │   │
│  │  FocusTimer                  │   │
│  │  StatisticsService           │   │
│  └──────────────────────────────┘   │
└──────────────┬──────────────────────┘
               │
               ↓
┌─────────────────────────────────────┐
│       数据访问层 (DAO)               │
│       DatabaseManager                │
└──────────────┬──────────────────────┘
               │
               ↓
┌─────────────────────────────────────┐
│          SQLite 数据库               │
└─────────────────────────────────────┘
```

**架构优势**：
- 结构简单直观，适合中小规模应用
- 开发速度快，QML和C++交互最少
- 单例服务边界清晰（任务、计时、统计）
- 适合单用户本地应用场景

### 3.3 核心C++组件

#### 3.3.1 TaskManager（任务管理服务）

**职责**：管理任务的增删改查和状态变更

**主要接口**：
```cpp
class TaskManager : public QObject {
    Q_OBJECT
public:
    static TaskManager* instance();
    
    // 任务操作
    Q_INVOKABLE void addTask(const QString& title, 
                             const QDate& date, 
                             const QString& category = "");
    Q_INVOKABLE void completeTask(int taskId);
    Q_INVOKABLE void deleteTask(int taskId);
    
    // 查询
    Q_INVOKABLE QVariantList getTodayTasks();
    Q_INVOKABLE QVariantList getWeekTasks();
    Q_INVOKABLE QVariantList getMonthTasks();
    
signals:
    void tasksChanged();  // 任务列表变化时通知QML
};
```

#### 3.3.2 FocusTimer（专注计时服务）

**职责**：管理专注计时和记录专注历史

**主要接口**：
```cpp
class FocusTimer : public QObject {
    Q_OBJECT
    Q_PROPERTY(int elapsedSeconds READ elapsedSeconds NOTIFY tick)
    Q_PROPERTY(bool isRunning READ isRunning NOTIFY runningStateChanged)
    
public:
    static FocusTimer* instance();
    
    Q_INVOKABLE void startFocus(int taskId);
    Q_INVOKABLE void pauseFocus();
    Q_INVOKABLE void resumeFocus();
    Q_INVOKABLE void stopFocus();  // 结束并保存
    
    int elapsedSeconds() const;
    bool isRunning() const;
    
signals:
    void tick();  // 每秒触发，用于UI更新
    void runningStateChanged();
    void focusCompleted(int duration);  // 专注结束
};
```

**实现细节**：
- 使用 `QTimer` 每秒触发一次
- 记录开始时间，计算已过秒数
- 暂停时保存当前已过时间，恢复时继续累加

#### 3.3.3 StatisticsService（统计服务）

**职责**：计算和提供各类统计数据

**主要接口**：
```cpp
class StatisticsService : public QObject {
    Q_OBJECT
public:
    static StatisticsService* instance();
    
    // 统计查询
    Q_INVOKABLE QVariantMap getTodayStats();
    Q_INVOKABLE QVariantList getWeekStats();
    Q_INVOKABLE QVariantMap getCategoryStats();
    
private:
    // 从数据库聚合计算
    int calculateTotalDuration(const QDate& date);
    QMap<QString, int> calculateCategoryDistribution();
};
```

**返回数据格式示例**：
```json
// getTodayStats() 返回
{
    "totalDuration": 9000,      // 总秒数
    "completedTasks": 5,
    "totalTasks": 8,
    "completionRate": 0.625
}

// getWeekStats() 返回
[
    {"date": "2026-06-09", "duration": 9000, "tasks": 8},
    {"date": "2026-06-10", "duration": 7200, "tasks": 6},
    ...
]
```

#### 3.3.4 DatabaseManager（数据库管理）

**职责**：封装SQLite操作，提供DAO接口

**主要功能**：
- 数据库初始化和版本管理
- 提供CRUD操作接口
- 事务管理
- 数据库连接管理

### 3.4 数据库设计

#### tasks 表（任务表）
```sql
CREATE TABLE tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,                -- 任务标题
    category TEXT,                      -- 科目分类（如"数据结构"、"操作系统"）
    date DATE NOT NULL,                 -- 任务日期
    completed BOOLEAN DEFAULT 0,        -- 是否完成（0=未完成，1=已完成）
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 索引
CREATE INDEX idx_tasks_date ON tasks(date);
CREATE INDEX idx_tasks_completed ON tasks(completed);
```

#### focus_sessions 表（专注记录表）
```sql
CREATE TABLE focus_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,                    -- 关联的任务ID（可为空）
    start_time TIMESTAMP NOT NULL,      -- 开始时间
    end_time TIMESTAMP,                 -- 结束时间
    duration INTEGER,                   -- 持续时长（秒）
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);

-- 索引
CREATE INDEX idx_sessions_task ON focus_sessions(task_id);
CREATE INDEX idx_sessions_start ON focus_sessions(start_time);
```

**数据完整性**：
- 任务删除时，关联的 `focus_sessions` 不删除（保留历史统计）
- `task_id` 设为 NULL，但 `duration` 等数据保留

### 3.5 QML层组织

```
qml/
├── main.qml                    # 应用入口
├── MainWindow.qml              # 主窗口（侧边栏+内容区）
├── views/
│   ├── TodayTaskView.qml       # 今日任务页
│   ├── WeekPlanView.qml        # 本周计划页
│   ├── MonthGoalView.qml       # 月度目标页
│   ├── FocusView.qml           # 专注页
│   └── StatisticsView.qml      # 数据统计页
└── components/
    ├── Sidebar.qml             # 侧边栏组件
    ├── TaskItem.qml            # 任务列表项组件
    ├── StatCard.qml            # 统计卡片组件
    ├── ChartBar.qml            # 柱状图组件
    └── ChartPie.qml            # 饼图组件
```

---

## 4. 核心业务流程

### 4.1 创建任务流程

```
用户点击"添加任务"
    ↓
弹出对话框（输入标题、日期、科目）
    ↓
QML 调用 TaskManager.addTask(title, date, category)
    ↓
C++ 插入数据库
    ↓
发送 tasksChanged() 信号
    ↓
QML 监听信号，自动刷新任务列表
```

### 4.2 专注计时流程

```
用户在今日任务页点击"开始专注"
    ↓
QML 调用 FocusTimer.startFocus(taskId)
    ↓
跳转到专注页（FocusView.qml）
    ↓
C++ 创建 focus_session 记录（start_time）
    ↓
启动 QTimer，每秒触发 tick() 信号
    ↓
QML 监听 tick()，更新计时器显示
    ↓
用户点击"结束专注"
    ↓
QML 调用 FocusTimer.stopFocus()
    ↓
C++ 更新 end_time 和 duration，保存到数据库
    ↓
发送 focusCompleted() 信号
    ↓
返回任务列表页
```

**暂停/恢复流程**：
- 暂停：停止 QTimer，记录当前已过时间
- 恢复：重启 QTimer，继续累加时间

### 4.3 查看统计流程

```
用户点击侧边栏"数据统计"
    ↓
QML 调用 StatisticsService.getTodayStats()
         StatisticsService.getWeekStats()
         StatisticsService.getCategoryStats()
    ↓
C++ 查询数据库并聚合计算：
  - 今日总时长 = SUM(duration) WHERE DATE(start_time) = today
  - 今日完成任务数 = COUNT(*) WHERE completed=1 AND date=today
  - 本周每日数据 = GROUP BY DATE(start_time)
  - 科目分配 = GROUP BY category, SUM(duration)
    ↓
返回数据给 QML
    ↓
QML 用图表组件渲染展示
```

---

## 5. 错误处理与边界情况

### 5.1 数据库错误

**初始化**：
- 启动时检查数据库文件，不存在则自动创建
- 创建失败时显示错误提示，无法继续使用应用

**操作失败**：
- 增删改操作失败时，在界面显示友好提示（如"保存失败，请重试"）
- 关键操作（如结束专注）失败时，数据保留在内存，允许重试

### 5.2 计时异常

**应用意外关闭**：
- 未结束的专注记录标记为异常（end_time 为 NULL）
- 下次启动时检测到未完成的 session：
  - 提示用户："检测到未完成的专注记录"
  - 选项：
    - 丢弃该记录
    - 手动输入实际专注时长并保存

**系统时间变更**：
- 检测到系统时间倒退时，停止当前计时并提示用户
- 避免产生负数或异常大的时长记录

### 5.3 数据完整性

**任务删除**：
- 删除任务时，关联的 `focus_sessions` 不删除
- 将 `task_id` 设为 NULL，保留历史数据用于统计

**数据迁移**：
- 未来版本如果需要修改数据库结构，使用版本号管理
- 启动时检查版本，执行必要的迁移脚本

---

## 6. 用户体验细节

### 6.1 任务操作

**完成动画**：
- 勾选任务后，显示打勾动画
- 1秒后任务置灰或淡出

**快速添加**：
- 支持 Enter 键快速创建任务
- 焦点自动聚焦到输入框

**拖拽排序**（可选）：
- 任务可以拖拽调整顺序
- 顺序保存到数据库（需增加 `order` 字段）

### 6.2 专注页体验

**视觉氛围**：
- 背景色稍微变暗或使用柔和渐变
- 营造专注、沉浸的氛围

**时间显示**：
- 格式：`02:35:12`（时:分:秒）
- 大字号居中显示

**可选增强**（V2考虑）：
- 播放白噪音或轻音乐
- 全屏模式（隐藏标题栏和系统通知）

### 6.3 数据统计呈现

**图表选择**：
- **本周趋势**：柱状图，横轴为日期，纵轴为时长
- **科目分配**：饼图，显示各科目占比

**关键数字突出**：
- 今日专注时长使用大字号（如 36px）
- 配合单位和描述文字

**数据格式化**：
- 时长显示：`2小时30分钟` 或 `2h 30m`
- 百分比：保留一位小数，如 `62.5%`

### 6.4 性能优化

**列表加载**：
- 任务列表超过100条时分页加载
- 使用虚拟滚动优化渲染性能

**统计缓存**：
- 统计数据按天缓存，避免频繁查询数据库
- 数据变化时（新增专注记录）自动失效缓存

**计时器精度**：
- 使用 `QTimer`，精确到秒即可
- 避免使用毫秒级精度，减少不必要的更新

---

## 7. 开发计划

### 7.1 MVP（最小可行版本）- 第一阶段

**目标**：实现核心功能，验证可用性

**功能清单**：
1. 基础架构搭建
   - 项目结构和 CMake 配置
   - 数据库初始化和迁移机制
   - 三个核心服务的基础实现

2. 今日任务页
   - 任务列表展示
   - 添加任务（标题、日期、科目）
   - 标记任务完成
   - "开始专注"按钮

3. 专注页
   - 计时器显示（HH:MM:SS）
   - 开始/暂停/停止功能
   - 结束后保存记录并返回

4. 简单统计
   - 今日总专注时长
   - 今日任务完成数/总数

**时间估算**：2-3周

### 7.2 第二阶段功能

**功能清单**：
5. 本周计划页
   - 按日期分组的任务列表
   - 添加未来任务

6. 完整数据统计页
   - 本周趋势柱状图
   - 科目分配饼图
   - 任务完成率统计

7. 月度目标页
   - 月视图日历
   - 任务概览

**时间估算**：1-2周

### 7.3 第三阶段优化

**功能清单**：
8. 视觉细节打磨
   - 任务完成动画
   - 页面切换过渡效果
   - 温暖纸感主题完善

9. 科目管理
   - 自定义科目列表
   - 科目颜色标记

10. 数据导出
    - 导出为 CSV 格式
    - 用于外部分析或备份

**时间估算**：1周

### 7.4 总体时间线

- **第一阶段（MVP）**：第1-3周
- **第二阶段**：第4-5周
- **第三阶段**：第6周
- **测试和修复**：第7周

**总计**：约7周完成完整版本

---

## 8. 技术风险与应对

### 8.1 Qt Quick/QML 学习曲线

**风险**：QML 语法和概念可能需要学习时间

**应对**：
- 先从简单的 QML 页面开始，逐步深入
- 参考 Qt 官方示例和文档
- 优先实现功能，后期优化性能和体验

### 8.2 QML 与 C++ 交互

**风险**：数据传递和信号槽机制可能出现问题

**应对**：
- 使用 `Q_PROPERTY` 和 `Q_INVOKABLE` 标准机制
- 数据类型使用 QML 原生支持的类型（`QVariantMap`, `QVariantList`）
- 及早测试跨层调用，确保通信正常

### 8.3 图表组件实现

**风险**：QML 原生不提供图表组件

**应对**：
- 使用 Qt Charts 模块（官方提供）
- 或使用 Canvas 手动绘制简单图表
- 优先使用现成库，避免重复造轮子

### 8.4 跨平台兼容性

**风险**：虽然 Qt 跨平台，但不同系统可能有细节差异

**应对**：
- 开发阶段主要在 macOS 测试
- 预留时间在 Windows/Linux 测试
- 使用 Qt 标准控件，避免平台特定代码

---

## 9. 未来扩展方向

### 9.1 数据同步
- 可选的云端备份功能
- 支持多设备同步（如宿舍电脑和实验室电脑）

### 9.2 番茄钟模式
- 可选的传统番茄钟模式（25分钟+5分钟休息）
- 定时提醒功能

### 9.3 复习提醒
- 根据艾宾浩斯遗忘曲线提醒复习
- 任务重复功能（如每日背单词）

### 9.4 学习报告
- 周报/月报自动生成
- 学习效率分析和建议

### 9.5 番茄币激励
- 完成任务获得虚拟货币
- 游戏化激励机制

---

## 10. 总结

本设计文档定义了一个面向考研学生的专注管理应用，核心特点包括：

- **简洁实用**：功能聚焦于任务管理和专注统计，避免功能膨胀
- **用户体验优先**：温暖纸感视觉风格，沉浸式专注页，直观的数据统计
- **技术架构清晰**：单例服务模式，职责明确，易于开发和维护
- **分阶段实现**：从 MVP 开始，逐步完善功能，确保每个阶段都可用

接下来将进入实现计划阶段，详细规划每个功能的开发步骤和技术细节。
