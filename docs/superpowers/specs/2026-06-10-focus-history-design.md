# 月度专注记录功能设计文档

## 1. 概述

### 1.1 功能描述
将"月度目标"页面改造为"专注历史"页面，展示用户每月的专注记录时间轴。用户可以通过日历选择日期，查看该日的所有专注记录（任务名称、开始时间、结束时间、专注时长）。

### 1.2 用户场景
- 用户打开"专注历史"页面，看到本月日历
- 日历上显示每天的总专注时长（如"3.7小时"）
- 点击某一天（如6月10日），下方显示该天的专注记录时间轴
- 时间轴从早到晚排列，显示：任务名称、时间段、专注时长
- 用户可以切换到其他月份查看历史记录

### 1.3 设计原则
- **数据驱动**：使用现有的focus_sessions表，不新增数据表
- **架构一致**：遵循Service + View分离模式
- **增量开发**：分阶段实施，每个阶段产出可运行的代码
- **性能优先**：月度数据一次加载，避免频繁查询数据库

---

## 2. 架构设计

### 2.1 技术栈
- **数据层**：C++17 + Qt 6 + SQLite
- **UI层**：Qt Quick/QML
- **现有依赖**：focus_sessions表、FocusSession模型、DatabaseManager

### 2.2 模块划分

**数据层 (C++)**
- `FocusHistoryService` 类（新建）- 专注记录查询服务

**UI层 (QML)**
- `MonthGoalView.qml`（重构）- 改造为专注历史视图
- 保留日历组件，移除任务相关逻辑

**集成点**
- `main.cpp` - 注册FocusHistoryService到QML
- `Sidebar.qml` - 修改入口文案
- `CMakeLists.txt` - 添加新文件到构建

### 2.3 数据流
```
用户操作 → MonthGoalView → FocusHistoryService → focus_sessions表
                                      ↓
                              QVariantList（专注记录）
                                      ↓
                              MonthGoalView（更新UI）
```

---

## 3. 数据模型设计

### 3.1 现有数据库表结构

```sql
-- 现有的focus_sessions表（无需修改）
CREATE TABLE focus_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,
    start_time TEXT NOT NULL,
    end_time TEXT,
    duration INTEGER,  -- 秒数
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
);
```

### 3.2 FocusHistoryService接口

```cpp
class FocusHistoryService : public QObject {
    Q_OBJECT
    
public:
    static FocusHistoryService* instance();
    
    // 获取指定月份的所有专注记录
    // 返回格式：[{id, taskId, taskTitle, startTime, endTime, durationSeconds, date}, ...]
    Q_INVOKABLE QVariantList getMonthSessions(int year, int month) const;
    
    // 获取指定日期的所有专注记录（按时间升序）
    Q_INVOKABLE QVariantList getDaySessions(const QDate& date) const;
    
    // 获取指定日期的总专注时长（秒数）
    Q_INVOKABLE int getDayTotalDuration(const QDate& date) const;
    
    // 工具方法：格式化时长（43分钟 / 1小时57分）
    Q_INVOKABLE QString formatDuration(int seconds) const;
    
private:
    explicit FocusHistoryService(QObject* parent = nullptr);
    
    // 从focus_sessions + tasks表联合查询
    QVariantList querySessions(const QString& whereClause) const;
};
```

### 3.3 返回数据格式

**getMonthSessions() / getDaySessions() 返回的QVariantList中每项包含：**

```cpp
{
    "id": 123,                          // 专注记录ID
    "taskId": 45,                       // 任务ID
    "taskTitle": "数学二",               // 任务标题
    "startTime": "2026-06-10T15:37:00", // 开始时间（ISO 8601）
    "endTime": "2026-06-10T17:34:00",   // 结束时间
    "durationSeconds": 7020,            // 时长（秒）
    "date": "2026-06-10"                // 日期（用于分组）
}
```

---

## 4. UI组件设计

### 4.1 MonthGoalView重构方案

**保留部分：**
- 页面标题区域（改为"专注历史"）
- 月份切换按钮（上月/本月/下月）
- 日历组件（7×6网格）
- 日期选择逻辑

**移除部分：**
- 3个统计卡片（本月任务、已完成、完成率）
- 任务列表（TaskItem组件）
- AddTaskDialog相关逻辑

**新增部分：**
- 日历格子显示总专注时长
- 专注记录时间轴组件

### 4.2 日历格子设计

**布局：**
- 上方：日期数字（13px Bold）
- 下方：总专注时长（11px Medium，颜色#d4a574）

**状态：**
| 状态 | 背景色 | 边框 | 说明 |
|------|--------|------|------|
| 普通 | #faf6ee | 1px #e8dfc8 | 有专注记录的日期 |
| 无记录 | #faf6ee | 1px #e8dfc8 | 不显示时长文字 |
| 悬停 | #fffef9 | 1px #d4a574 | 鼠标悬停 |
| 选中 | #f0e6d2 | 2px #d4a574 | 当前选中日期 |

**示例：**
```qml
Rectangle {
    // 日期格子
    Text {
        text: "10"
        font.pixelSize: 13
        font.weight: Font.Bold
        color: "#5d4e37"
    }
    Text {
        visible: dayTotalDuration > 0
        text: focusHistoryService.formatDuration(dayTotalDuration)
        font.pixelSize: 11
        color: "#d4a574"
    }
}
```

### 4.3 专注记录时间轴设计

**布局结构：**
```
┌─────────────────────────────────────┐
│  6月10日 专注记录                    │
├─────────────────────────────────────┤
│  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  │ 数学二          1小时57分        │
│  │ 15:37 - 17:34   已完成          │
│  ●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  │ 数学二          47分钟           │
│  │ 17:40 - 18:27   已完成          │
│  ●                                  │
│  │ 408             43分钟           │
│  │ 18:31 - 19:14   已完成          │
└─────────────────────────────────────┘
```

**时间轴条目卡片：**
- 背景：#faf8f3
- 边框：1px #e8dfc8
- 圆角：6px
- 内边距：12px
- 左侧时间轴线：2px #e8dfc8
- 时间节点：10px圆点 #d4a574

**内容布局：**
- 左上：任务标题（15px Medium #3d3327）
- 左下：时间段（12px Normal #8b7355）
- 右上：专注时长（18px Bold #d4a574）
- 右下：状态标签（11px Medium #4caf50）

### 4.4 空状态设计

**无专注记录时显示：**
```qml
Text {
    visible: selectedDaySessions.length === 0
    text: "这一天还没有专注记录"
    font.pixelSize: 13
    color: "#8b7355"
}
```

---

## 5. 交互流程设计

### 5.1 页面加载流程
1. MonthGoalView.onCompleted 触发
2. 调用 `focusHistoryService.getMonthSessions(currentYear, currentMonth)`
3. 返回本月所有专注记录
4. 计算每天的总时长（按日期分组聚合）
5. 更新日历显示
6. 默认选中今天，显示今天的专注记录时间轴

### 5.2 点击日期流程
1. 用户点击日期格子
2. `selectedDay = dayNumber`
3. 从 `monthSessions` 中过滤出 `date === selectedDate` 的记录
4. 按 `startTime` 升序排序
5. 更新时间轴显示

### 5.3 切换月份流程
1. 用户点击"上月"/"下月"按钮
2. 计算新的 `currentYear` 和 `currentMonth`
3. 调用 `getMonthSessions(newYear, newMonth)`
4. 清空时间轴
5. 重置 `selectedDay = 1`
6. 更新页面标题显示

### 5.4 时长格式化规则
```cpp
QString FocusHistoryService::formatDuration(int seconds) const
{
    if (seconds < 60) return "0分钟";
    int minutes = seconds / 60;
    if (minutes < 60) return QString("%1分钟").arg(minutes);
    int hours = minutes / 60;
    int remainMinutes = minutes % 60;
    if (remainMinutes == 0) return QString("%1小时").arg(hours);
    return QString("%1小时%2分").arg(hours).arg(remainMinutes);
}
```

**示例：**
- 43分钟 → "43分钟"
- 117分钟 → "1小时57分"
- 120分钟 → "2小时"

---

## 6. 错误处理与边界情况

### 6.1 数据查询错误
- **数据库连接失败**：返回空列表，页面显示"加载失败"
- **SQL执行失败**：记录qWarning日志，返回空列表

### 6.2 输入边界
- **无效月份**：限制在1-12之间
- **无效年份**：限制在2000-2100之间
- **未来日期**：允许显示，但通常无数据

### 6.3 特殊情况
- **本月无专注记录**：日历显示正常，所有格子无时长文字
- **选中日期无记录**：时间轴区域显示"这一天还没有专注记录"
- **任务已删除**：taskTitle显示为"未知任务"
- **时长为0**：显示"0分钟"

### 6.4 性能考虑
- **月度数据缓存**：一次查询本月所有记录，前端按日期过滤
- **日历聚合**：前端计算每天总时长，避免每个格子都查询数据库
- **大数据量处理**：假设每月最多1000条记录（30天×33条/天）

---

## 7. 测试策略

### 7.1 单元测试（Qt Test）

**FocusHistoryServiceTest**
- `testGetMonthSessions()` - 查询指定月份的记录
- `testGetDaySessions()` - 查询指定日期的记录
- `testGetDayTotalDuration()` - 计算日总时长
- `testFormatDuration()` - 时长格式化（各种边界值）
- `testEmptyMonth()` - 查询无记录的月份
- `testCrossMonthQuery()` - 跨月边界情况

### 7.2 集成测试
- 启动应用 → 点击"专注历史" → 验证页面加载
- 点击不同日期 → 验证时间轴更新
- 切换月份 → 验证数据刷新
- 选择无记录的日期 → 验证空状态显示

### 7.3 手动测试清单
- [ ] 日历显示正确的月份和日期
- [ ] 有专注记录的日期显示总时长
- [ ] 点击日期后时间轴正确显示
- [ ] 时间轴按时间升序排列
- [ ] 时长格式化正确（分钟/小时）
- [ ] 月份切换功能正常
- [ ] 空状态显示正确
- [ ] 任务标题正确显示

---

## 8. 实施计划概要

本功能将分为9个主要阶段实施，每个阶段产出可编译运行的代码：

### 阶段1：创建FocusHistoryService框架
- 创建.h和.cpp文件
- 定义类结构和方法签名
- 实现空方法体（返回默认值）

### 阶段2：实现数据库查询逻辑
- 实现 `getMonthSessions()`
- 实现SQL查询和数据转换
- 处理LEFT JOIN获取任务标题

### 阶段3：实现辅助方法
- 实现 `getDaySessions()`
- 实现 `getDayTotalDuration()`
- 实现 `formatDuration()`

### 阶段4：注册服务到QML
- 修改main.cpp
- 修改CMakeLists.txt

### 阶段5：重构MonthGoalView - 移除旧逻辑
- 移除统计卡片
- 移除任务列表相关代码
- 保留日历结构

### 阶段6：添加专注记录数据绑定
- 添加 `monthSessions` 属性
- 实现 `refresh()` 方法
- 绑定到focusHistoryService

### 阶段7：改造日历显示逻辑
- 计算每天总时长
- 修改日历格子显示
- 更新hover状态

### 阶段8：实现时间轴组件
- 创建时间轴布局
- 实现记录卡片
- 添加空状态

### 阶段9：完善交互和样式
- 优化动画效果
- 统一颜色和字体
- 测试所有交互

---

## 9. 文件清单

### 9.1 新建文件
- `src/services/FocusHistoryService.h`
- `src/services/FocusHistoryService.cpp`

### 9.2 修改文件
- `CMakeLists.txt` - 添加新Service到构建
- `src/main.cpp` - 注册focusHistoryService到QML
- `qml/views/MonthGoalView.qml` - 重构为专注历史视图
- `qml/components/Sidebar.qml` - 修改入口文案（可选）

---

## 10. 未来扩展

### 10.1 可选功能（暂不实施）
- 专注记录的详细信息弹窗
- 按任务分类筛选专注记录
- 周视图、年视图切换
- 专注记录的编辑/删除功能
- 导出月度专注报告

### 10.2 性能优化
- 实现月度数据缓存
- 优化大数据量渲染（虚拟滚动）
- 添加加载状态指示器

---

## 11. 总结

本设计文档定义了月度专注记录功能的完整实现方案，包括：
- **架构设计**：FocusHistoryService + MonthGoalView重构
- **数据模型**：复用focus_sessions表，通过Service层封装查询
- **UI设计**：日历显示总时长 + 时间轴展示详细记录
- **交互设计**：日期选择、月份切换、数据更新
- **实施策略**：9个阶段增量开发

设计遵循现有架构模式，确保代码质量和可维护性。
