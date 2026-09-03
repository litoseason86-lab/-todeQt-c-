# 043：待办课表页（每周固定时间表）

## 状态

- **状态**：已实施，全量 ctest 67/67 通过
- **优先级**：P1
- **执行分支**：`feature/weekly-todo-view`
- **边界**：课表项**不是任务**。它不写 `tasks`、不写 `focus_sessions`、不产生今日待办、
  不参与任何统计与目标进度。它是一张按星期几循环的时间表，只做展示与增删改。

## 需求来源与澄清

用户要的「待办」页用来显示**工作或学习课表**，不是现有的「本周计划」。
两者的根本差别在于数据的时间锚点：

| | 本周计划（`tasks`） | 待办课表（`schedule_entries`） |
| --- | --- | --- |
| 时间锚点 | 具体日期 `2026-09-02` | 星期几 + 时段 `周一 08:00–09:40` |
| 生命周期 | 做完就结束 | 每周循环，按周次生效 |
| 完成状态 | 有 | 无 |

现有 `routines`（每日例行）同样不能复用：它没有星期几、没有时段，语义是「每天都做」。

## 已确认的产品规则

1. **时间表示**：底层统一存起止时间（分钟数）。另提供一套可配置的**节次预设**用于快速填充，
   并支持两种显示模式切换——「时间轴」按真实时长成比例排布，「节次」按节次等高排布。
2. **周次**：每个课表项可填生效周次范围（如第 1–8 周）与单双周规则（每周／仅单周／仅双周）。
   需要「学期起始日」与「总周数」两项设置来把日期换算成周次。
3. **联动**：纯展示。不接专注计时，不生成任务。
4. **侧栏入口**：新增「待办」，现有「本周计划」暂时保留并存，由用户实际使用后再决定去留。

## 分层与职责

| 层 | 文件 | 责任 |
| --- | --- | --- |
| DB | `DatabaseManager` | 新增 `schedule_entries`、`schedule_periods` 两表，schema 升到 v13（纯新增，不改旧表） |
| 服务 | `src/services/ScheduleService.{h,cpp}` | 课表项与节次的增删改查、**按周次筛选**、时间冲突检测 |
| 换算 | `qml/ScheduleWeeks.js` | 日期 ↔ 周次的纯函数换算，与既有 `LogicalDay.js` 同构 |
| 视图 | `qml/views/SchedulePlanView.qml` | 周网格、周次导航、两种显示模式 |
| 弹窗 | `qml/components/ScheduleEntryDialog.qml` | 课表项增改 |
| 弹窗 | `qml/components/ScheduleSettingsDialog.qml` | 学期起始日、总周数、节次预设 |
| 设置 | `AppSettings` | `semesterStartDate`、`semesterWeeks`、`scheduleDisplayMode`、`scheduleShowWeekend` |

**分层要点**：C++ 只管存储与「给定周次筛选」，不关心今天是第几周；
日期→周次的换算全部在 QML 侧的 `ScheduleWeeks.js`。这样服务层无需依赖 `AppSettings`，
周次规则也能被 QML 测试直接覆盖。

## 数据结构

### `schedule_entries`

```sql
CREATE TABLE IF NOT EXISTS schedule_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
    location TEXT NOT NULL DEFAULT '',
    weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),   -- 1=周一 … 7=周日
    start_minutes INTEGER NOT NULL CHECK(start_minutes BETWEEN 0 AND 1439),
    end_minutes INTEGER NOT NULL CHECK(end_minutes BETWEEN 1 AND 1440),
    week_start INTEGER NOT NULL DEFAULT 1 CHECK(week_start >= 1),
    week_end INTEGER NOT NULL DEFAULT 30 CHECK(week_end >= 1),
    week_parity INTEGER NOT NULL DEFAULT 0 CHECK(week_parity IN (0, 1, 2)), -- 0每周 1单周 2双周
    category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK(end_minutes > start_minutes),
    CHECK(week_end >= week_start)
)
```

`end_minutes > start_minutes` 表示课表项不跨零点。课表场景不存在跨夜条目，
用 CHECK 挡住比在服务层反复判空更可靠。

### `schedule_periods`

```sql
CREATE TABLE IF NOT EXISTS schedule_periods (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    period_index INTEGER NOT NULL UNIQUE CHECK(period_index >= 1),
    start_minutes INTEGER NOT NULL CHECK(start_minutes BETWEEN 0 AND 1439),
    end_minutes INTEGER NOT NULL CHECK(end_minutes BETWEEN 1 AND 1440),
    CHECK(end_minutes > start_minutes)
)
```

迁移时种入一套默认节次（上午 4 节、下午 4 节、晚上 3 节），用户可整表改写。

## 不变量

- 课表项与 `tasks`、`focus_sessions` 之间**没有任何外键或写入关系**。
  删除课表项不影响任何专注历史；删除科目只把 `category_id` 置空。
- 「按周次筛选」的判据是三段合取：`weekday` 命中、`week_start ≤ N ≤ week_end`、
  单双周奇偶命中。三者任一不满足即不出现在该周网格里。
- 冲突检测只做**提示**不做拦截：同一天两门课时间重叠是真实存在的情况
  （比如两个可选时段），强行拒绝会让用户录不进去。
- 节次预设整表替换必须在单个事务内完成，避免中途失败留下半张节次表。

## 分阶段执行

1. ~~DB 层：两张表 + `migrateToVersion13` + 默认节次种子 + CMake 注册。~~
2. ~~`ScheduleService`：CRUD、按周次查询、冲突检测；补 C++ 单测。~~
3. ~~QML 骨架：`ScheduleWeeks.js`、视图框架、侧栏入口、`MainWindow` 接线。~~
4. ~~网格渲染：时间轴模式与节次模式。~~
5. ~~弹窗：课表项增改、课表设置。~~
6. ~~验证：QML 测试、全量 `ctest`。~~

## 实施中发现并修正的问题

- **嵌套布局的 `Layout.fillHeight` 默认值**：布局类型（RowLayout/ColumnLayout）嵌在另一个
  布局里时该属性默认为 `true`，不是 `false`。课表列头因此和网格主体一起瓜分纵向空间，
  把整页撑成七根从上贯到底的大色条。列头与页头都必须显式写 `Layout.fillHeight: false`。
  离屏截图走查抓到了这个问题——它不会让任何测试转红，因为断言的是属性值而不是像素。
- **时间刻度的首个整点被切掉**：刻度文字以刻度线为中心，`08:00` 的上半截落在滚动区外。
  网格顶部留 `axisTopInset` 的空白，横线与列各自按需补上这段偏移。
- **对比度**：时间刻度最初用 `Theme.inkMuted`，夜间 3.95:1、日间 3.31:1，均低于 4.5:1。
  时刻是有意义的正文信息而非占位符，改用 `Theme.inkSoft`（该令牌按主题定义即为满足 AA）。
- **`ServiceTests` 里写死的 schema 版本**：`migrationV12...` 断言迁移后 `user_version == 12`，
  但 `createTables` 会把整条链跑到头。改为断言 `kCurrentSchemaVersion`，
  否则以后每加一次迁移都会误伤这条用例。

## 第二轮质量复审（在第一轮 14 项修完之后）

第一轮修的是「点了会出错」的问题，这一轮找的是「点了没反应、或者悄悄不一致」的问题。
七项全部先用测试复现、修完再用变异验证（把修复改回去，确认对应用例会红）。

- **学期结束后「本周」是个死控件**：`enabled` 只判 `currentWeekIndex >= 1`。
  学期 16 周而今天已是第 20 周时按钮仍可点，但 `goToWeek(20)` 会被 `clampWeek` 夹回 16，
  页面纹丝不动，副标题也不会出现「（本周）」——用户得不到任何解释。
  改为按 `currentWeekInSemester`（今天是否落在 `1..semesterWeeks`）决定可用性，
  并在副标题写明「学期已结束」。点了没反应的控件比灰掉的控件更让人困惑。
- **同一条目被两条提示重复认领**：一门周六 12:30 的课，在「周末列关闭 + 按节次」下
  同时进了 `hiddenWeekendEntries` 和 `unplacedEntries`，横幅会说「有 1 项在周末……；
  有 1 项不在任何节次内……」，读起来像丢了两项。`unplacedEntries` 改为只扫
  当前版式真正画得出来的条目。
- **隐藏的周末条目仍在撑时间轴**：一门周六 6:00 的课会让周一到周五凭空多出两小时空白，
  而屏幕上找不到任何东西解释那段空白属于谁。轴范围改为只看可见条目。
- **说明文字用了「占位/禁用」色**：课表设置里两句用户必须读懂才知道该填什么的说明
  用了 `Theme.inkMuted`。该令牌在 `Theme.qml` 的定义就是占位与禁用，对比度不到 4.5:1。
  与第一轮那条时间刻度是同一个错误，改用 `Theme.inkSoft`。
- **macOS 上键盘删不掉**：`Keys.onDeletePressed` 对应 `Qt.Key_Delete`，
  而 Mac 笔记本主键盘上那颗写着 delete 的键发的是 `Qt.Key_Backspace`
  （`Key_Delete` 需要 fn+delete）。本项目只发 macOS，等于键盘通路实际不存在，
  而注释还写着「键盘用户可以聚焦后按 Delete」。补 `Keys.onPressed` 接管 Backspace，
  且只接管它——不能把 Delete 与 Return 一起吞掉。
- **课表设置保存的半提交**：学期起始日、总周数、周末开关先写，节次后写，两者不在同一事务。
  节次被服务端拒绝（数量超限或时间重叠）时，前三项已经落库，而用户看到的是
  「节次保存失败」，多半会按「取消」离开，以为什么都没改。把服务端会拒绝的两条
  提到写设置之前先查；顺带按用户填的行号报错，而不是服务端排序后的编号。
- **相交判据在 QML 里写了三遍**：抽成 `ScheduleWeeks.overlaps`。这是半开区间
  （紧邻的 08:45 结束与 08:45 开始不算相交），写三遍迟早有一处把 `<` 写成 `<=`，
  表现是「相邻两节课被判成冲突」这种只在边界现形的毛病。补了专门的边界用例。

### 顺带修的两处测试自身的问题

- **对比度门禁从没扫过课表页**：`tst_contrast_audit` 的视图清单里没有 `schedule`，
  整页自加入起就在门禁之外——上面那条 `inkMuted` 正是这样漏过全量测试的。
  补进清单，并给设置替身补上学期锚点，让它进到画出网格的状态而不是停在首次引导态
  （否则列头胶囊、刻度、课程块这些真正有风险的文字一个都扫不到）。
  用「故意改坏一个颜色」验证过门禁确实走到了这一页。
- **新用例的状态还原写在用例末尾**：断言一失败就跳过还原，一条真实失败会污染后面每一条。
  实测变异一次会红 4 条，其中 3 条与改动无关。改为在 `init()` 里从基线整体重置，
  同一个变异只红 1 条。

## 第三轮：版式与控件外观

用户反馈两件事：页头「太乱、太有塑料感」，以及课表内容不突出、地点看不清、留白太多。
全程用 `tests/qml/preview_schedule_scene.qml` 离屏走查——按用户真实窗口宽度（900/760）
和真实的 8 条课表渲染，而不是拿 1200 宽走查；宽窗口会把「地点被截断」这类问题全部藏起来。

### 页头：从四套形状语言收敛到两套

原先一行里并排着四种控件：34px 的胶囊分段控件、三颗 40px / 圆角 6 的独立描边按钮
（间距 1px，读起来像一个裂开的分段控件，还刚好挨着真正的分段控件）、一颗同款方形图标按钮，
以及一块实心焦糖的「添加」。高度 34 与 40 混排、胶囊与 6px 圆角混排，这就是「乱」。

- 统一控件高度到 34（`controlHeight`），与分段控件的 `implicitHeight` 对齐。
- 周次导航收进一条与分段控件同款的凹槽轨道，内部只用发丝线分隔。页头于是只剩
  「凹槽轨道」与「实心按钮」两种形状。
- 设置改为无底无框的幽灵按钮，只在悬停时浮出底色——它是这一行最次级的动作。
- **「添加」改用 tinted button**。`Theme.qml` 明确规定大面积色块走暖罩 + 深焦糖文字，
  实心焦糖只留给细线条；十余个弹窗的提交按钮与倒计时、目标、今日三页的主按钮都是暖罩，
  唯独课表页是实心。塑料感的主要来源就是它，改动同时是在纠正一处与全仓相左的实现。

### 课程块：地点必须读得全

900px 窗口下七列平分，每列只有约 107px。原先地点一行装不下就省略，
真实课表里 7 个地点有 5 个被截成「A1教学楼A151…」——这一格于是回答不了「我该去哪」。

- 地点改为换行显示（最多两行）并提到正文色；块内纵向本来就有富余。
- 课程名按列宽分级（窄列 12px、宽列 13px），靠 DemiBold + inkStrong 承担层级，
  块内因此只有两个字号。13px 在窄列会把「Java EE框架技术」断出一个孤字「术」，
  比小一号难读得多。
- 时间与周次范围合并成一行；**单双周移到右下角角标**。角标不占行高也不占行宽，
  因此在最窄的块里也能保住——而它是唯一「不写出来就会让人以为课表出错」的信息。
  角标先放右上角，实测会挤掉课程名的宽度（「Java EE框架技术」被截成「Java EE…」），
  改到右下角，那里对齐的是地点最后一行的短尾巴。

### 纵向预算：不允许出现半行字

地点换行后，90px 高的块会把最后一行从中间切开露出半个字，看起来像渲染坏了。
先按「字号 × 1.35」估算行高排预算，结果算漏了 Column 的行间距、系数也偏小，
时间那行照样被切。**实测才发现真实行高是字号的 1.63–1.67 倍**——`lineHeight: 1.15`
叠在 Qt 本就约 1.42 倍的中文行高上，每行白占 15%。
最终改成读排版后的真实坐标：每一行只在「底边仍落在预算内」时才画，
并去掉多余的 `lineHeight`。Column 里靠前的行的 y 不受靠后的行影响，这样引用不会形成绑定环。

### 减少留白

- 页边距 24→16、面板内边距 12→10、刻度栏 52→44、列间距 4→3，合计还给内容约 38px。
- 周末列底色透明度 0.45→0.22。这份课表周六周日一门课都没有，两条空列原先的视觉重量
  和有课的列相当，眼睛会被拉到右边一片什么都没有的地方去。
  （取色核对过：调整后两套主题下与工作日列的差异都只有约 1.5%，
  目测「夜间偏亮」是边缘对比错觉，实测是更暗 4 个色阶。）
- 节次模式的刻度栏原先每节各画一张描边小卡，八节叠起来比它标注的课程块还抢眼，
  改成与时间轴刻度一致的纯文字。

### 仍然存在、但不该由代码替用户决定的

这份课表全部集中在周二到周四，七列里有四列常年空着。关掉「显示周末」后每列能宽出约 40%，
课程名、地点、时间、周次可以全部单行显示（见走查图 `_weekday`）。
但这是 `scheduleShowWeekend` 设置项的职责，且第二轮已经补了「周末有课却被隐藏」的提示横幅；
代码不替用户翻这个开关。
