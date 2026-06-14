# 统计页趋势对比功能设计文档

**版本**: 1.0  
**日期**: 2026-06-14  
**状态**: 设计阶段

---

## 1. 概述

### 1.1 功能描述

在数据统计页面的统计卡片中添加同比/环比对比信息，让用户直观感知自己的进步或退步。每个卡片底部显示与前一时间段的百分比变化，使用绿色↗表示增长，红色↘表示下降。

### 1.2 用户场景

- 用户打开统计页面"今日"模式，看到"今日专注: 2小时45分 ↗ +15% vs 昨天"
- 用户感知到：今天比昨天进步了，获得正向激励
- 切换到"本周"模式，看到"本周累计: 18小时30分 ↘ -8% vs 上周"
- 用户意识到本周需要加强，产生调整动机
- 通过箭头导航查看历史数据时，对比基准自动调整（例如查看上周数据时，对比显示"vs 上上周"）

### 1.3 设计原则

- **即时可见**：对比信息无需额外操作，打开统计页即可看到
- **视觉直观**：颜色和箭头方向清晰表达增减趋势
- **克制简洁**：只显示最核心的对比维度，避免信息过载
- **动态适配**：对比基准随选中时间段自动调整

---

## 2. UI设计

### 2.1 视觉设计

**对比信息样式**：

- 文字大小：13px
- 间距：距离卡片主数据 8px
- 颜色方案：
  - 上升：↗ 绿色 `#4caf50`
  - 下降：↘ 红色 `#f44336`
  - 持平：→ 灰色 `#8b7355`（0%变化或数据不足时）
- 文字格式：`[箭头] [±百分比] vs [时间段]`
  - 示例：`↗ +15% vs 昨天`
  - 示例：`↘ -8% vs 上周`
  - 示例：`→ 0% vs 上月`（持平）

**卡片布局调整**：

```text
┌─────────────────────────┐
│ 今日专注                │  ← 标题（13px, 粗体）
│                         │
│ 2小时45分               │  ← 主数据（28px, 粗体）
│                         │
│ ↗ +15% vs 昨天          │  ← 新增：对比信息（13px）
└─────────────────────────┘
```

### 2.2 布局位置

**应用范围**：

统计页三种模式下的所有统计卡片：

1. **今日模式**：
   - "今日专注"卡片 → 显示 vs 昨天
   - "任务完成"卡片 → 显示 vs 昨天
   - （如有更多卡片，同理）

2. **本周模式**：
   - "本周累计"卡片 → 显示 vs 上周
   - "有效天数"卡片 → 显示 vs 上周
   - "专注次数"卡片 → 显示 vs 上周

3. **本月模式**：
   - "本月累计"卡片 → 显示 vs 上月
   - "有效天数"卡片 → 显示 vs 上月
   - "专注次数"卡片 → 显示 vs 上月

**不显示对比的情况**：

- 数据不足：前一时间段无数据时，不显示对比（或显示"无历史数据"）
- 除零错误：前一时间段数值为0时，显示"首次记录"而非百分比

---

## 3. 数据模型设计

### 3.1 对比逻辑定义

**今日模式对比**：
- 对比基准：前一个自然日
- 示例：2026-06-14（今天）vs 2026-06-13（昨天）
- 箭头导航时：查看 2026-06-10 时，对比 2026-06-09

**本周模式对比**：
- 对比基准：前一个完整自然周（周一到周日）
- 示例：2026-06-09～06-15（本周）vs 2026-06-02～06-08（上周）
- 箭头导航时：查看 2026-06-02～06-08 时，对比 2026-05-26～06-01

**本月模式对比**：
- 对比基准：前一个完整自然月
- 示例：2026年6月 vs 2026年5月
- 跨年：2026年1月 vs 2025年12月
- 箭头导航时：查看 2026年5月 时，对比 2026年4月

### 3.2 百分比计算规则

**计算公式**：

```text
变化百分比 = ((当前值 - 前一值) / 前一值) × 100%
```

**特殊情况处理**：

1. **前一值为0**：
   - 当前值 > 0：显示 "首次记录"（不显示百分比）
   - 当前值 = 0：显示 "→ 0%"（持平）

2. **前一值不存在**（无历史数据）：
   - 不显示对比信息

3. **百分比显示格式**：
   - 正数：+15%、+150%
   - 负数：-8%、-50%
   - 零：0%
   - 精度：四舍五入到整数

4. **趋势判定**：
   - 变化 > 0：上升 ↗ 绿色
   - 变化 < 0：下降 ↘ 红色
   - 变化 = 0：持平 → 灰色

**示例数据**：

| 当前值 | 前一值 | 变化百分比 | 显示 |
|--------|--------|-----------|------|
| 165分钟 | 120分钟 | +37.5% → +38% | ↗ +38% vs 昨天 |
| 90分钟 | 120分钟 | -25% | ↘ -25% vs 昨天 |
| 120分钟 | 120分钟 | 0% | → 0% vs 昨天 |
| 60分钟 | 0分钟 | 无穷大 | 首次记录 |
| 0分钟 | 无数据 | N/A | （不显示对比）|

---

## 4. 技术实现

### 4.1 Service层改造

**新增方法 - StatisticsService.h**：

```cpp
// 获取对比统计数据
Q_INVOKABLE QVariantMap getComparisonStats(
    const QDate& currentDate, 
    const QDate& previousDate,
    const QString& metricType  // "duration", "tasks", "sessions" 等
) const;

// 便捷方法：自动计算前一日期
Q_INVOKABLE QVariantMap getDayComparison(const QDate& date) const;
Q_INVOKABLE QVariantMap getWeekComparison(const QDate& weekStart) const;
Q_INVOKABLE QVariantMap getMonthComparison(int year, int month) const;
```

**返回数据结构**：

```cpp
QVariantMap {
    "currentValue": 165,      // 当前值（秒/个数）
    "previousValue": 120,     // 前一值
    "changePercent": 38,      // 百分比（整数）
    "trend": 1,               // 趋势：1=上升, 0=持平, -1=下降
    "displayText": "↗ +38% vs 昨天",  // 格式化显示文本
    "hasData": true           // 是否有有效对比数据
}
```

**实现逻辑（StatisticsService.cpp）**：

```cpp
QVariantMap StatisticsService::getDayComparison(const QDate& date) const
{
    QDate previousDate = date.addDays(-1);
    
    int currentDuration = calculateTotalDuration(date);
    int previousDuration = calculateTotalDuration(previousDate);
    
    return buildComparisonResult(
        currentDuration, 
        previousDuration, 
        "昨天"
    );
}

QVariantMap StatisticsService::buildComparisonResult(
    int currentValue, 
    int previousValue, 
    const QString& label
) const
{
    QVariantMap result;
    result["currentValue"] = currentValue;
    result["previousValue"] = previousValue;
    
    if (previousValue == 0) {
        if (currentValue > 0) {
            result["displayText"] = "首次记录";
            result["trend"] = 1;
            result["hasData"] = true;
        } else {
            result["displayText"] = "→ 0%";
            result["trend"] = 0;
            result["hasData"] = true;
        }
        result["changePercent"] = 0;
        return result;
    }
    
    double changeRatio = (double)(currentValue - previousValue) / previousValue;
    int changePercent = qRound(changeRatio * 100);
    
    result["changePercent"] = changePercent;
    result["hasData"] = true;
    
    QString arrow;
    int trend;
    if (changePercent > 0) {
        arrow = "↗";
        trend = 1;
    } else if (changePercent < 0) {
        arrow = "↘";
        trend = -1;
    } else {
        arrow = "→";
        trend = 0;
    }
    
    result["trend"] = trend;
    result["displayText"] = QString("%1 %2%3% vs %4")
        .arg(arrow)
        .arg(changePercent > 0 ? "+" : "")
        .arg(changePercent)
        .arg(label);
    
    return result;
}
```

### 4.2 QML组件改造

**StatCard.qml 新增属性**：

```qml
Rectangle {
    id: root
    
    // 现有属性
    property string title: ""
    property string value: "0"
    property string unit: ""
    property string subtitle: ""
    
    // 新增：对比数据属性
    property string comparisonText: ""      // 对比显示文本
    property int comparisonTrend: 0         // 趋势：1=上升, 0=持平, -1=下降
    property bool showComparison: false     // 是否显示对比
    
    // ... 现有布局代码 ...
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 6
        
        // 标题
        Text { /* ... */ }
        
        // 主数据
        RowLayout { /* ... */ }
        
        // 副标题
        Text { /* ... */ }
        
        // 新增：对比信息
        Text {
            Layout.fillWidth: true
            visible: root.showComparison && root.comparisonText.length > 0
            text: root.comparisonText
            font.pixelSize: 13
            color: {
                if (root.comparisonTrend > 0) return "#4caf50"      // 绿色
                if (root.comparisonTrend < 0) return "#f44336"      // 红色
                return "#8b7355"                                     // 灰色
            }
            elide: Text.ElideRight
        }
    }
}
```

**StatisticsView.qml 数据绑定**：

```qml
// 今日模式示例
StatCard {
    title: "今日专注"
    value: root.totalDurationValue(root.todayStats.totalDuration)
    unit: root.totalDurationUnit(root.todayStats.totalDuration)
    
    // 新增：绑定对比数据
    showComparison: true
    comparisonText: root.todayComparison.displayText || ""
    comparisonTrend: root.todayComparison.trend || 0
}

// 新增：对比数据属性
property var todayComparison: ({})
property var weekComparison: ({})
property var monthComparison: ({})

// 在 refresh() 函数中查询对比数据
function refresh() {
    // ... 现有查询逻辑 ...
    
    if (currentTimeRange === "today") {
        root.todayStats = statisticsService.getDayStats(selectedDate)
        root.todayComparison = statisticsService.getDayComparison(selectedDate)
    } else if (currentTimeRange === "week") {
        // ...
        root.weekComparison = statisticsService.getWeekComparison(selectedWeekStart)
    } else if (currentTimeRange === "month") {
        // ...
        root.monthComparison = statisticsService.getMonthComparison(selectedYear, selectedMonth)
    }
}
```

---

## 5. 测试策略

### 5.1 功能测试

- [ ] 今日模式显示 vs 昨天的对比
- [ ] 本周模式显示 vs 上周的对比
- [ ] 本月模式显示 vs 上月的对比
- [ ] 箭头导航到历史数据时，对比基准正确调整
- [ ] 上升趋势显示绿色箭头
- [ ] 下降趋势显示红色箭头
- [ ] 持平显示灰色箭头
- [ ] 前一值为0时显示"首次记录"
- [ ] 无历史数据时不显示对比信息

### 5.2 边界测试

- [ ] 跨月对比：6月1日 vs 5月31日
- [ ] 跨年对比：2026年1月 vs 2025年12月
- [ ] 极端数值：从0分钟到300分钟（+无穷大）
- [ ] 极端数值：从300分钟到0分钟（-100%）
- [ ] 百分比精度：165分钟 vs 120分钟 = +37.5% → 显示 +38%
- [ ] 本周跨年：2025年12月29日（周一）vs 2025年12月22日（周一）

### 5.3 视觉测试

- [ ] 对比文字不超出卡片宽度
- [ ] 颜色对比度符合可读性要求
- [ ] 多个卡片的对比信息对齐一致
- [ ] 数值变化时，对比信息同步更新

---

## 6. 实施计划概要

本功能分为3个主要阶段实施：

### 阶段1：Service层实现
- 实现 `buildComparisonResult()` 辅助方法
- 实现 `getDayComparison()` 方法
- 实现 `getWeekComparison()` 方法
- 实现 `getMonthComparison()` 方法
- 单元测试：验证百分比计算和边界情况

### 阶段2：StatCard组件改造
- 添加 `comparisonText`、`comparisonTrend`、`showComparison` 属性
- 添加对比信息的Text元素
- 实现颜色根据趋势动态变化
- 验证布局不会溢出

### 阶段3：StatisticsView集成
- 添加 `todayComparison`、`weekComparison`、`monthComparison` 属性
- 在 `refresh()` 函数中查询对比数据
- 将对比数据绑定到各个StatCard
- 完整功能测试

---

## 7. 文件清单

### 修改文件

- `src/services/StatisticsService.h` - 新增对比查询方法声明
- `src/services/StatisticsService.cpp` - 实现对比逻辑和百分比计算
- `qml/components/StatCard.qml` - 添加对比显示属性和UI
- `qml/views/StatisticsView.qml` - 查询并绑定对比数据

### 无需新建文件

所有功能通过修改现有文件实现

---

## 附录：与现有功能的兼容性

- 完全兼容现有统计页面布局
- 不影响箭头导航功能
- 不影响时间范围切换功能
- StatCard 的现有属性和动画保持不变
- 对比功能可以通过 `showComparison: false` 单独禁用
