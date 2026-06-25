# 每日例行任务（自动出现）· 设计

- 日期：2026-06-16
- 范围：任务功能 —— 让固定的每日任务自动出现，免去每天手动重复录入

## 背景与目标

考研每天的任务高度固定（背单词、数学、政治、英语等）。当前 `TaskManager` 只有 `addTask`，没有任何重复机制，用户每天早上要把同样几项一条条重加，是最高频、最纯粹的时间浪费。

**目标**：用户把固定项设一次为「每日例行」，之后每天**自动**出现在当天任务清单里，零日常操作。

**非目标（v1 不做）**：
- 星期几粒度（只支持「每天」）
- 「例行」小徽标 / 把已有任务一键设为例行
- 补生成历史日期（隔天没开 App 不回填过去）

## 架构选择

生成**真实的 `tasks` 行**，而不是「虚拟显示」。理由：现有 `tasks` 是按日期的真实行，完成状态、数据统计、专注会话全部依赖真实行。生成真实行让这些能力全自动兼容，无需任何特例分支。

## 数据模型

新增 `routines` 表（数据库迁移到 version 3，复用现有迁移框架）：

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | |
| `title` | TEXT NOT NULL CHECK(trim>0) | 例行项标题 |
| `category_id` | INTEGER NULL REFERENCES categories(id) | 可空科目 |
| `active` | INTEGER NOT NULL DEFAULT 1 | 是否启用 |
| `display_order` | INTEGER NOT NULL DEFAULT 0 | 列表顺序 |
| `last_generated_date` | TEXT | 最近一次生成当天任务的日期（ISO），用于幂等 |
| `created_at` | TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP | |

**不修改 `tasks` 表**：生成出来的就是普通任务行，可独立编辑/删除，与手动添加的任务完全一视同仁。

迁移注意：`migrateToVersion3()` 仅 `CREATE TABLE IF NOT EXISTS routines`（无 ALTER），并把 user_version 置 3；与 version 2 迁移同样用事务包裹、失败回滚。旧库（version 2）升级后 routines 为空，行为等同「无例行项」，向后兼容。

## 服务层：RoutineManager

新增 `RoutineManager` 单例（仿 `TaskManager` / `CategoryManager`：私有构造 + `instance()` + 注册为 QML context property `routineManager`）。

QML 可调用方法：
- `Q_INVOKABLE bool addRoutine(const QString& title, int categoryId)` —— categoryId 用 -1 表示不设科目
- `Q_INVOKABLE bool updateRoutine(int id, const QString& title, int categoryId)`
- `Q_INVOKABLE bool deleteRoutine(int id)`
- `Q_INVOKABLE bool setRoutineActive(int id, bool active)`
- `Q_INVOKABLE QVariantList getRoutines() const` —— 返回 id/title/category_id/category_name/category_color/active/display_order，按 display_order
- `Q_INVOKABLE int materializeToday()` —— 见下，返回本次新生成的任务数
- 信号 `routinesChanged()`

### materializeToday() 生成逻辑（幂等、防复活、不补历史）

```
today = QDate::currentDate()
对每个 active 且 (last_generated_date 为空 或 < today) 的 routine：
    插入一条今天的 tasks 行（title、category_id、date=today、completed=0）
    UPDATE routines SET last_generated_date = today WHERE id = routine.id
返回新生成条数；结束发 tasksChanged（让今日页刷新）
```

- **幂等**：靠 `last_generated_date`（不是「今天是否已存在该标题的行」），重复调用当天不重复生成。
- **删了不复活**：今天生成的例行任务被删掉后，因 `last_generated_date == today` 已记录，当天不再生成。
- **不补历史**：只比较到 `today`，隔几天没开 App 再开只生成今天，不回填过去日期，避免堆一坨过期任务。

插入任务复用现有写库路径（与 `TaskManager::addTask(title, dateValue, categoryId)` 一致的列与约定），确保 category 文本/category_id 双写逻辑保持一致。

### 调用时机
- `main.cpp` 启动、`DatabaseManager` 初始化成功后调用一次 `RoutineManager::instance()->materializeToday()`。
- 今日页 `TodayTaskView` 的 `refresh()` 里再调一次（幂等，安全）——覆盖「App 一直开着、跨过午夜」的情况。

## 交互 / UI

沿用现有「侧栏底部管理项 → 弹窗」模式（与 `科目管理` 一致）：

- **Sidebar**：底部「科目管理 / 数据导出」一组里新增 **「每日例行」**（marker「例」），点击发 `dailyRoutineRequested()`，由 `MainWindow` 打开 `RoutineDialog`。
- **RoutineDialog**（仿 `CategoryDialog`）：
  - 顶部：单行标题输入 + 科目下拉 + 「添加」按钮
  - 列表：每个例行项显示 标题 + 科目色点；右侧「启用」开关 + 「删除」
  - 空状态：一句引导「把每天都要做的任务加进来，以后自动出现在今日清单。」
- **今日页无新增按钮**：例行任务每天自动出现在清单中（由 materialize 生成）。

文案用主动语气、面向用户（「添加」「删除」「启用」），错误用内联提示，与现有对话框一致。

## 边界与错误处理

- 停用 / 删除某例行项 → 只停未来生成，已生成的任务行不动。
- 编辑例行项标题/科目 → 只影响以后生成的任务，不改既有任务行。
- 过去未完成的任务 → 留在其原日期（不自动结转），今天只给新生成的。
- 标题为空/全空白 → 拒绝，内联提示，与 addTask 的校验一致。
- DB 未打开 / 语句失败 → 与现有服务一致：`qWarning` + 返回 false，不崩。

## 测试

**C++（ServiceTests）**——用内存/临时库：
- add/get/delete/setActive 基本往返
- `materializeToday` 幂等：连续调两次只生成一份
- 删掉今天生成的任务后再调 `materializeToday` 不复活
- 只生成今天：把某 routine 的 `last_generated_date` 设为数天前，调用后该日期变为今天且只新增一条（不补中间天数）
- 停用的 routine 不生成

**QML（新增 tst_routine_dialog.qml）**：
- 注入假 `routineManager`，RoutineDialog 能添加并在列表中显示该项
- 控件在面板内、不溢出（沿用现有对话框测试断言风格）

## 文件清单（实现时）

- 迁移：`src/services/DatabaseManager.{h,cpp}` 加 `migrateToVersion3()` + `createRoutinesTable()`
- 服务：`src/services/RoutineManager.{h,cpp}`（新）
- 接线：`src/main.cpp`（注册 context property + 启动生成）
- UI：`qml/components/RoutineDialog.qml`（新）、`qml/components/Sidebar.qml`（加入口项）、`qml/MainWindow.qml`（打开弹窗）、`qml/views/TodayTaskView.qml`（refresh 调 materialize）
- 资源：`resources/qml.qrc` 注册 RoutineDialog.qml
- 构建：`CMakeLists.txt` 把 RoutineManager.cpp 加入 APP_SOURCES 与测试目标
- 测试：`tests/ServiceTests.cpp`（扩展）、`tests/qml/tst_routine_dialog.qml`（新）
