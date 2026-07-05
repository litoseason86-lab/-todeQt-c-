# 任务管理补洞（结转 + 编辑 + 删除撤销）设计文档

日期：2026-07-06
状态：三段设计已逐段确认

## 背景

2026-07-05 用户视角审计确认任务管理停在 MVP：不能编辑、删除不可逆、未完成任务跨天消失。本设计是后台清单的**迭代一**，覆盖 P0 的 ①任务编辑 ②删除撤销 ③未完成结转 与 P1 的 ⑨删除按钮 hover 化（与撤销同属删除流，顺手完成）。

已确认的交互决策：

- 结转：**横幅一键全部**（范围＝所有逾期未完成的非例行任务，不止昨天）。
- 编辑：**行内改标题（双击）+ 弹窗改全部**（标题/科目/日期，日期用 今天/明天/后天 快捷项）。

## 结构性决策：例行任务血缘（方案 A，已确认）

`tasks` 表没有例行标记（[DatabaseManager.cpp](src/services/DatabaseManager.cpp) v1 建表），结转若不排除例行任务，昨天未完成的"背单词"会与今天 `materializeToday` 新生成的同名任务撞成两条。

**Schema v4 迁移**（沿用 v2/v3 模式）：

- `ALTER TABLE tasks ADD COLUMN routine_id INTEGER REFERENCES routines(id)`；
- 存量回填（尽力而为）：`UPDATE tasks SET routine_id = (SELECT id FROM routines WHERE routines.title = tasks.title) WHERE routine_id IS NULL AND EXISTS(...)` ——消除历史例行任务混入首次结转横幅的噪音；同名普通任务被误标的代价只是不参与结转，可接受；
- `RoutineManager::materializeToday` 的 INSERT 增加 `routine_id` 字段写入来源例行 id。

否决：按标题排除（零迁移但静默漏判/误伤）；不排除（每天撞车）。

## 数据层（TaskManager 新接口）

全部 `Q_INVOKABLE`，成功后发 `tasksChanged`：

| 接口 | 行为 |
| --- | --- |
| `bool updateTask(int taskId, const QString& title, int categoryId, const QVariant& dateValue)` | 更新三字段；标题 trim 后非空校验（与 addTask 一致）；categoryId ≤ 0 视为无科目；日期无效则拒绝。行内改标题时其余字段传原值。 |
| `QVariantList getOverdueUncompletedTasks()` | `date < today AND completed = 0 AND routine_id IS NULL`，按 date 升序。返回结构同 getTodayTasks。 |
| `bool moveTasksToToday(const QVariantList& taskIds)` | 事务内批量 `UPDATE tasks SET date = today`；任一失败整体回滚。 |

删除撤销不加新接口，复用现有 `deleteTask`（延迟触发，见下）。

## 结转横幅（今日页）

- `TodayTaskView.refresh()` 时调 `getOverdueUncompletedTasks()`；非空且今天未忽略 → 任务列表上方显示横幅：**"之前还有 N 个未完成任务 [全部移到今天] [忽略]"**。
- 全部移到今天 → `moveTasksToToday(ids)` + 刷新（横幅消失，任务出现在今日列表）。
- 忽略 → `AppSettings` 新键 `rollover/lastIgnoredDate` 记今天；当天不再显示，明天若仍有逾期任务自动再提。
- 横幅样式对齐现有 CountdownBanner 的暖纸卡片语言；不新增全局组件。

## 任务编辑

**行内改标题**（高频路径）：

- TaskItem 标题 Text 双击 → 原位切换为 `TextField`（预填原标题，全选，聚焦）；
- Enter → `updateTask(taskId, 新标题, 原categoryId, 原date)`；Esc 或失焦 → 放弃还原；
- 空标题提交视为取消（不调接口）；完成态任务同样可编辑。
- TaskItem 需要新增 `taskCategoryId`、`taskDate` 属性由视图传入（updateTask 要传原值）。

**编辑弹窗**（低频全字段）：

- TaskItem hover 时露出"编辑"按钮（与删除按钮同排、同 hover 规则）；
- 新组件 `qml/components/EditTaskDialog.qml`，骨架参照 AddTaskDialog：标题输入 + 科目下拉 + 日期快捷项（今天/明天/后天 三个互斥 chip；任务当前日期命中其一则默认选中；不命中则三个 chip 均不选中、旁边以小字显示原日期，用户不点任何 chip 时保留原日期不变）；
- 确认 → `updateTask` 全字段；今日页与周视图共用（组件级能力，弹窗实例放各视图，同 AddTaskDialog 模式）。

## 删除撤销 + hover 化

**为什么必须延迟删除**：`deleteTask` 先把 `focus_sessions.task_id` 置 NULL 再删任务行（[TaskManager.cpp:255-257](src/services/TaskManager.cpp#L255-L257)）——解绑不可逆，"删了再插回"会永久丢失任务↔专注记录关联。撤销窗口内不碰数据库。

**机制**（集中到 MainWindow，同 `startFocusForTask` 模式）：

- 视图不再直接调 `deleteTask`，上抛 `deleteRequested(taskId, title)`；
- MainWindow 维护 `pendingDeleteTaskId`（-1 表示无），注入今日/周视图；视图 `loadTasks` 时过滤隐藏该行（乐观 UI）；
- Toast 组件扩展可选 action：`show(message, actionText, actionCallback)`，action 为空时行为不变；
- 显示"已删除「标题」 [撤销]"，5 秒超时 → 真调 `deleteTask(pendingDeleteTaskId)` 并清 pending；点撤销 → 清 pending + 刷新，行恢复，零数据损失；
- 单槽：新删除到来时先立即提交上一个 pending；应用中途退出 → 未提交的删除自然失效，任务保留（失败朝安全方向）。

**hover 化（⑨）**：

- "删除"与新增"编辑"按钮 `visible` 绑 `itemHovered`（现成 `pointerInside` 状态）；"开始专注"保持常驻；
- 已完成任务隐藏"开始专注"（不再置灰占位 + tooltip）。

## 错误处理

- `updateTask`/`moveTasksToToday` 失败 → 视图 loadError 或 Toast 提示，数据回滚由事务保证；
- 迁移失败 → 与 v2/v3 相同策略（启动失败并保留原库，不半迁移）；
- 行内编辑提交失败 → 还原显示原标题 + loadError 提示。

## 测试策略

**C++（ServiceTests）**：

- v4 迁移：新库直建含 routine_id；旧库升级后列存在；回填命中/不命中；迁移幂等（重复跑不重复改）。
- `materializeToday` 生成行带 routine_id。
- `updateTask`：改标题/科目/日期各自生效；空标题拒绝；无效 id 拒绝。
- `getOverdueUncompletedTasks`：排除今天、排除已完成、排除 routine_id 非空；日期升序。
- `moveTasksToToday`：批量成功；含无效 id 时整体回滚。
- `deleteTask` 行为不变（既有测试守护）。

**QML（tst 今日页/TaskItem/主窗口流）**：

- 横幅：有逾期任务出现、点结转后消失且列表刷新、忽略后当天不再现（mock AppSettings 日期键）。
- 行内编辑：双击出现 TextField、Enter 调 mock updateTask 收参正确、Esc 还原、空标题不调接口。
- 编辑弹窗：预填当前值、日期快捷项选择、确认收参正确。
- 延迟删除：deleteRequested 后行被过滤隐藏、撤销恢复、超时（注入短时长）后 mock deleteTask 被调、第二个删除立即提交第一个。
- hover 化：删除/编辑按钮 visible 绑定源（`itemHovered`）断言，完成态"开始专注"隐藏——遵守不断言 `visible === true` 纪律（断言驱动属性或用 `itemHovered` 显式置位后断言按钮 `enabled`/文本）。

## 影响面与拆分建议

- C++：DatabaseManager（v4）、RoutineManager（INSERT 一处）、TaskManager（三接口）。
- QML：TaskItem（行内编辑 + hover 化 + 新属性）、TodayTaskView（横幅 + 注入）、WeekPlanView（删除流改上抛 + 弹窗实例）、MainWindow（延迟删除 + Toast action）、Toast（action 扩展）、新增 EditTaskDialog。
- 实施计划建议拆两份：**计划一**＝数据层（迁移 + 三接口 + materializeToday）+ 结转横幅；**计划二**＝编辑（行内 + 弹窗）+ 延迟删除撤销 + hover 化。计划一独立可交付（结转先跑起来），计划二依赖计划一的 updateTask。
