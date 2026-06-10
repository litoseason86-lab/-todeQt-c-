# 数据统计页面时间范围切换功能设计文档

## 1. 概述

### 1.1 功能描述
在数据统计页面添加时间范围切换器，用户可以通过下拉选择器在"今日"、"本周"、"本月"三种数据视图之间切换。切换后，页面的3个统计卡片、柱状图和饼图都会更新为对应时间范围的数据。

### 1.2 用户场景
- 用户打开数据统计页面，默认显示"今日"数据
- 用户点击右上角的时间范围切换器，下拉菜单显示"今日"、"本周"、"本月"三个选项
- 选择"本周"后，3个卡片变为：有效天数、专注次数、本周累计；柱状图显示本周7天趋势
- 选择"本月"后，3个卡片变为：有效天数、专注次数、本月累计；柱状图显示每周汇总（第1周、第2周...）
- 饼图始终显示当前选择时间范围的科目分配

### 1.3 设计原则
- **UI一致性**：时间范围切换器与现有温暖纸质主题融合
- **数据完整性**：切换时间范围后，所有数据组件都响应变化
- **空间优化**：合理利用页面空间，避免右侧留白过多
- **用户体验**：默认显示"今日"，符合用户查看当天数据的习惯

---

## 2. 架构设计

### 2.1 技术栈
- **数据层**：C++17 + Qt 6 + SQLite
- **UI层**：Qt Quick/QML
- **现有依赖**：StatisticsService、focus_sessions表、tasks表

### 2.2 模块划分

**数据层 (C++)**
- 扩展 `StatisticsService` 类 - 新增月度统计、有效天数、专注次数、周汇总等方法

**UI层 (QML)**
- `StatisticsView.qml`（修改）- 添加时间范围切换器，重构数据绑定逻辑
- 3个 `StatCard` 组件 - 动态绑定标题和数据
- `ChartBar` 组件 - 根据时间范围显示不同粒度数据
- `ChartPie` 组件 - 根据时间范围更新数据源

**集成点**
- `StatisticsService.h/.cpp` - 新增方法实现
- `StatisticsView.qml` - 添加切换器和数据绑定逻辑

### 2.3 数据流
```
用户点击时间范围切换器 → currentTimeRange变化
                          ↓
                    refresh()函数触发
                          ↓
根据currentTimeRange调用不同的Service方法
                          ↓
    todayStats/weekStats/monthStats更新
                          ↓
        StatCard和Chart组件自动更新显示
```

---

## 3. 数据模型设计

### 3.1 时间范围枚举

在QML中使用字符串表示：
- `"today"` - 今日
- `"week"` - 本周
- `"month"` - 本月

### 3.2 StatisticsService新增方法

```cpp
class StatisticsService : public QObject {
    Q_OBJECT
    
public:
    // 现有方法
    Q_INVOKABLE QVariantMap getTodayStats() const;
    Q_INVOKABLE QVariantList getWeekStats() const;
    Q_INVOKABLE QVariantMap getCategoryStats(const QVariant& startDateValue, 
                                             const QVariant& endDateValue) const;
    
    // 新增方法
    Q_INVOKABLE QVariantMap getMonthStats() const;
    Q_INVOKABLE int getEffectiveDays(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE int getFocusSessionCount(const QDate& startDate, const QDate& endDate) const;
    Q_INVOKABLE QVariantList getMonthWeeklySummary() const;
    
private:
    // 辅助方法
    QList<QDate> getUniqueFocusDates(const QDate& startDate, const QDate& endDate) const;
    QPair<QDate, QDate> getWeekRange(const QDate& mondayOfWeek) const;
};
```

### 3.3 返回数据格式

**getMonthStats() 返回的QVariantMap：**
```cpp
{
    "totalDuration": 86400,        // 本月总时长（秒）
    "effectiveDays": 15,           // 有效天数
    "sessionCount": 42,            // 专注次数
    "completedTasks": 30,          // 完成任务数
    "totalTasks": 45               // 总任务数
}
```

**getMonthWeeklySummary() 返回的QVariantList：**
```cpp
[
    {
        "label": "第1周",
        "duration": 21600,         // 该周总时长（秒）
        "startDate": "2026-06-02", // 周一日期
        "endDate": "2026-06-08"    // 周日日期
    },
    {
        "label": "第2周",
        "duration": 25200,
        "startDate": "2026-06-09",
        "endDate": "2026-06-15"
    },
    // ... 最多5周
]
```

---

## 4. UI组件设计

### 4.1 时间范围切换器

**位置**：页面标题行右侧

**布局结构**：
```qml
RowLayout {
    // 左侧：标题和副标题
    ColumnLayout {
        Text { text: "数据统计"; font.pixelSize: 24; font.bold: true; color: "#5d4e37" }
        Text { text: "看清时间流向，比靠感觉复盘可靠。"; font.pixelSize: 13; color: "#8b7355" }
    }
    
    Item { Layout.fillWidth: true }  // 弹性空间
    
    // 右侧：时间范围切换器
    Rectangle {
        // 切换按钮
        width: 110
        height: 36
        color: "#faf6ee"
        border.width: 1
        border.color: "#e8dfc8"
        radius: 6
        
        Row {
            Text { text: "📅 今日"; font.pixelSize: 14; color: "#5d4e37" }
            Text { text: "▼"; font.pixelSize: 12; color: "#8b7355" }
        }
        
        MouseArea {
            onClicked: timeRangeMenu.open()
        }
    }
}

Menu {
    id: timeRangeMenu
    // 3个MenuItem: 今日、本周、本月
}
```

**样式规范**：
- 背景色：`#faf6ee`
- 边框：1px `#e8dfc8`
- 圆角：6px
- 字体：14px Medium `#5d4e37`
- 图标：📅 emoji
- 下拉箭头：`#8b7355`

**下拉菜单样式**：
- 背景：`#faf8f3`
- 边框：1px `#d4a574`
- 圆角：8px
- 阴影：`0 4px 12px rgba(93,78,55,0.15)`
- 菜单项悬停：背景 `#f0e6d2`
- 菜单项高度：40px
- 内边距：10px 16px

### 4.2 统计卡片动态内容

**今日模式：**
| 卡片 | 标题 | 数值 | 副标题 |
|------|------|------|--------|
| 1 | 任务完成 | X / Y | 完成率 Z% |
| 2 | 专注次数 | N次 | 今日完成次数 |
| 3 | 今日专注 | X分钟/小时 | 当前自然日 |

**本周模式：**
| 卡片 | 标题 | 数值 | 副标题 |
|------|------|------|--------|
| 1 | 有效天数 | X天 | 本周有记录天数 |
| 2 | 专注次数 | N次 | 本周完成次数 |
| 3 | 本周累计 | X小时 | 本周专注时长 |

**本月模式：**
| 卡片 | 标题 | 数值 | 副标题 |
|------|------|------|--------|
| 1 | 有效天数 | X天 | 本月有记录天数 |
| 2 | 专注次数 | N次 | 本月完成次数 |
| 3 | 本月累计 | X小时 | 本月专注时长 |

### 4.3 柱状图显示规则

**标题动态变化：**
- 今日/本周模式：`"本周专注趋势"`
- 本月模式：`"本月专注趋势"`

**数据来源：**
- 今日/本周模式：`root.barData()` - 基于 `weekStats`，显示7根柱子（周一到周日）
- 本月模式：`root.monthBarData()` - 基于 `monthWeeklySummary`，显示每周汇总（最多5根柱子）

**空状态：**
- 今日/本周模式：`"本周还没有专注记录"`
- 本月模式：`"本月还没有专注记录"`

### 4.4 饼图显示规则

**标题保持不变：**
- `"科目时间分配"`

**数据来源根据时间范围：**
- 今日模式：`getCategoryStats(今日开始, 今日结束)`
- 本周模式：`getCategoryStats(本周一, 本周日)`
- 本月模式：`getCategoryStats(本月1号, 本月最后一天)`

**空状态：**
- 今日模式：`"今日还没有可归类的专注记录"`
- 本周模式：`"本周还没有可归类的专注记录"`
- 本月模式：`"本月还没有可归类的专注记录"`

### 4.5 空间优化方案

**问题**：当前右侧留白过多

**解决方案：**
1. **调整左右边距**：将 `Layout.leftMargin` 和 `Layout.rightMargin` 从 24px 增加到 32px，让内容更居中
2. **增加卡片间距**：将 `spacing` 从 12px 增加到 16px，让卡片之间更透气
3. **优化图表宽度**：确保图表充分利用可用宽度，通过 `Layout.fillWidth: true` 自动填充
4. **调整切换器宽度**：切换器最小宽度110px，确保文字和图标舒适显示

---

## 5. 交互流程设计

### 5.1 页面加载流程
1. StatisticsView.onCompleted 触发
2. 初始化 `currentTimeRange = "today"`
3. 调用 `refresh()` 函数
4. 根据 `currentTimeRange` 调用 `statisticsService.getTodayStats()`
5. 更新 `todayStats`、`weekStats`（用于柱状图）、`categoryStats`
6. 所有组件自动更新显示

### 5.2 切换时间范围流程
1. 用户点击时间范围切换器
2. Menu弹出，显示3个选项
3. 用户点击"本周"
4. `currentTimeRange = "week"`
5. 调用 `refresh()` 函数
6. 根据新的 `currentTimeRange` 调用对应Service方法
7. 更新数据属性
8. 卡片标题、数值、柱状图、饼图全部更新
9. Menu关闭

### 5.3 数据刷新逻辑

```qml
property string currentTimeRange: "today"  // 默认今日

function refresh() {
    try {
        root.loadError = ""
        
        if (currentTimeRange === "today") {
            // 今日模式
            root.todayStats = statisticsService.getTodayStats()
            root.weekStats = statisticsService.getWeekStats()  // 用于柱状图
            
            // 饼图：今日数据
            var today = new Date()
            root.categoryStats = statisticsService.getCategoryStats(
                Qt.formatDate(today, "yyyy-MM-dd"),
                Qt.formatDate(today, "yyyy-MM-dd")
            )
        } 
        else if (currentTimeRange === "week") {
            // 本周模式
            root.weekStats = statisticsService.getWeekStats()
            var start = root.mondayOf(new Date())
            
            // 卡片数据：从weekStats计算
            var effectiveDays = statisticsService.getEffectiveDays(start, root.endOfWeek(start))
            var sessionCount = statisticsService.getFocusSessionCount(start, root.endOfWeek(start))
            var totalDuration = root.weekTotalDuration()
            
            root.todayStats = {
                effectiveDays: effectiveDays,
                sessionCount: sessionCount,
                totalDuration: totalDuration
            }
            
            // 饼图：本周数据
            root.categoryStats = statisticsService.getCategoryStats(
                Qt.formatDate(start, "yyyy-MM-dd"),
                Qt.formatDate(root.endOfWeek(start), "yyyy-MM-dd")
            )
        }
        else if (currentTimeRange === "month") {
            // 本月模式
            root.monthStats = statisticsService.getMonthStats()
            root.monthWeeklySummary = statisticsService.getMonthWeeklySummary()
            
            // 饼图：本月数据
            var firstDay = new Date(new Date().getFullYear(), new Date().getMonth(), 1)
            var lastDay = new Date(new Date().getFullYear(), new Date().getMonth() + 1, 0)
            root.categoryStats = statisticsService.getCategoryStats(
                Qt.formatDate(firstDay, "yyyy-MM-dd"),
                Qt.formatDate(lastDay, "yyyy-MM-dd")
            )
        }
    } catch (error) {
        root.loadError = "统计数据加载失败"
        // 设置默认值
    }
}
```

---

## 6. 错误处理与边界情况

### 6.1 数据查询错误
- **数据库连接失败**：显示 `loadError`，所有数据显示默认值0
- **SQL执行失败**：记录qWarning日志，返回空数据

### 6.2 输入边界
- **今日无专注记录**：卡片显示0，柱状图显示本周数据，饼图显示空状态
- **本周无专注记录**：所有数据显示0，图表显示空状态
- **本月无专注记录**：所有数据显示0，图表显示空状态

### 6.3 特殊情况
- **本月第1周不完整**：从本月1号开始计算，不包含上月天数
- **本月最后1周不完整**：到本月最后一天结束，不包含下月天数
- **有效天数计算**：只统计有至少1条有效专注记录（duration >= 3分钟）的天数
- **专注次数计算**：统计所有completed的focus_session记录数

### 6.4 性能考虑
- **数据缓存**：切换时间范围后的数据不缓存，每次都重新查询（保证数据实时性）
- **查询优化**：使用DATE()函数和索引优化SQL查询性能
- **UI更新**：使用属性绑定自动更新，避免手动刷新DOM

---

## 7. 测试策略

### 7.1 单元测试（C++ Qt Test）

**StatisticsServiceTest**
- `testGetMonthStats()` - 验证本月统计数据正确性
- `testGetEffectiveDays()` - 验证有效天数计算（各种边界情况）
- `testGetFocusSessionCount()` - 验证专注次数统计
- `testGetMonthWeeklySummary()` - 验证周汇总计算（不完整周、完整周）
- `testEmptyMonth()` - 验证无数据月份的处理
- `testCrossingMonthBoundary()` - 验证跨月边界的数据隔离

### 7.2 集成测试
- 启动应用 → 打开数据统计页面 → 验证默认显示"今日"
- 点击切换器 → 选择"本周" → 验证所有组件更新
- 点击切换器 → 选择"本月" → 验证柱状图变为周汇总
- 切换回"今日" → 验证数据正确回到今日模式
- 在无数据状态下切换 → 验证空状态正确显示

### 7.3 手动测试清单
- [ ] 时间范围切换器位置正确（标题行右侧）
- [ ] 点击切换器弹出下拉菜单
- [ ] 菜单样式符合温暖主题
- [ ] 选择"今日"后3个卡片显示正确
- [ ] 选择"本周"后3个卡片变为有效天数/专注次数/本周累计
- [ ] 选择"本月"后3个卡片变为有效天数/专注次数/本月累计
- [ ] 今日/本周模式柱状图显示7天
- [ ] 本月模式柱状图显示每周汇总
- [ ] 饼图跟随时间范围切换
- [ ] 空状态文案正确
- [ ] 页面排版没有右侧过度留白
- [ ] 所有颜色符合温暖纸质主题

---

## 8. 实施计划概要

本功能将分为5个主要阶段实施：

### 阶段1：扩展StatisticsService
- 实现 `getMonthStats()`
- 实现 `getEffectiveDays()`
- 实现 `getFocusSessionCount()`
- 实现 `getMonthWeeklySummary()`

### 阶段2：StatisticsView添加时间范围状态
- 添加 `currentTimeRange` 属性
- 添加 `monthStats` 和 `monthWeeklySummary` 属性
- 重构 `refresh()` 函数支持多模式

### 阶段3：实现时间范围切换器UI
- 添加切换按钮
- 实现QML Menu下拉菜单
- 绑定点击事件

### 阶段4：重构卡片和图表数据绑定
- 卡片标题和数据动态绑定
- 柱状图数据源切换
- 饼图数据源切换
- 空状态处理

### 阶段5：优化排版和样式
- 调整左右边距
- 优化组件间距
- 测试不同屏幕尺寸下的显示效果

---

## 9. 文件清单

### 9.1 修改文件
- `src/services/StatisticsService.h` - 添加新方法声明
- `src/services/StatisticsService.cpp` - 实现新方法
- `qml/views/StatisticsView.qml` - 添加切换器，重构数据绑定

### 9.2 无需新建文件
所有功能通过修改现有文件实现

---

## 10. 未来扩展

### 10.1 可选功能（暂不实施）
- 自定义时间范围（选择任意日期区间）
- 数据对比功能（本周 vs 上周）
- 导出统计报表
- 趋势分析和预测

### 10.2 性能优化
- 实现智能数据缓存
- 优化大数据量图表渲染
- 添加加载状态指示器

---

## 11. 总结

本设计文档定义了数据统计页面时间范围切换功能的完整实现方案，包括：
- **UI设计**：标题行右侧QML Menu下拉切换器
- **数据模型**：扩展StatisticsService支持月度统计、有效天数、专注次数、周汇总
- **交互设计**：默认今日模式，切换后全部组件响应
- **空间优化**：调整边距和间距，避免右侧留白过多
- **实施策略**：5个阶段增量开发

设计遵循现有架构模式和温暖纸质主题，确保代码质量和用户体验。
