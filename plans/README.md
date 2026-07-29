# 实施计划索引

由 improve skill 于 2026-07-26 生成，基于 commit `43ba2ee`。
按下表顺序执行，除非依赖关系另有要求。每位执行者：**先完整读完计划再动手**，
遵守其中的 STOP conditions，做完更新自己那一行的状态。

> **本仓库的特殊情况**：`43ba2ee` 时工作区有一批未提交的新文件（长期目标功能：
> `src/models/LongGoal.*`、`src/services/GoalService.*`、`tests/GoalServiceTests.cpp`，
> 以及 `CMakeLists.txt`、`src/main.cpp`、`src/services/FocusSessionRules.h`、
> `src/services/TaskManager.cpp`、`tests/ServiceTests.cpp` 的改动）。
> 计划 002 和 004 针对的正是这批代码，它们的 drift check **不能用 `git diff`**，
> 各自计划里已给出替代的比对方式。

## 执行顺序与状态

| 计划 | 标题 | 优先级 | 工作量 | 依赖 | 状态 |
|------|------|--------|--------|------|------|
| 001 | 恢复回滚失败后数据库必须重新打开，并为异步回滚补失败路径测试 | P1 | M | — | DONE（已复核） |
| 002 | 长期目标必须绑定科目，且写入要么整体成功要么整体失败 | P1 | S | — | DONE（已复核） |
| 003 | 给部署删除加护栏、锁定 Qt 版本下界、校正构建文档 | P2 | S | — | DONE（已复核） |
| 004 | 为长期目标的删除与重排补单元测试 | P2 | S | 002 | DONE（已复核） |
| 005 | 缩短测试用的本地套接字名，让测试套件在 Qt 6.7+ 全版本都能跑绿 | P1 | S | — | DONE（Qt 6.9/6.11 已验证） |
| 006 | 目标列表页 + 侧栏入口 + 表单（奖励机制·阶段 A） | P1 | M | — | DONE（已验证） |
| 007 | 详情页 100 格 + 完成预测 + 热力（奖励机制·阶段 B） | P1 | M | 006 | DONE（已验证） |
| 008 | 全局奖励回路：Toast/弹窗/粒子/音效（奖励机制·阶段 C，核心） | P1 | M-L | 006, 007 | DONE（已验证） |
| 009 | 统计页等级与已达成列表（奖励机制·阶段 D） | P2 | S-M | 006 | DONE（已验证） |
| 010 | 给 v8/v9 迁移回填补逐行特征测试 | P1 | M | — | DONE（已验证） |
| 011 | 「有效番茄」口径收回唯一事实源 + 迁移两个数据安全缺口 | P1 | S | **010** | DONE（已验证） |
| 012 | 仪表盘「今日专注番茄」改用有效番茄口径 | P1 | S | 011 | DONE（已验证） |
| 013 | 奖励回路三缺陷（粒子被遮挡 / 失败态伪装成空态 / 复选框绑定断裂） | P1 | S-M | — | DONE（前两项修复；复选框缺陷未复现，已收敛单一状态源） |
| 014 | 音效与 QML 资源清单守门测试 | P2 | S | — | DONE（已验证） |
| 015 | 玻璃卡描边改用对比细线，修亮壁纸下卡片边界消失 | P2 | M | — | TODO |

状态取值：TODO | IN PROGRESS | DONE | BLOCKED（附一行原因）| REJECTED（附一行理由）

> **给 010-014 的执行者：漂移检查不能用 `git diff`。** 这五份计划针对的代码
> **全部还在工作区、没有提交**（HEAD 仍是 `43ba2ee`，工作区有 77 个文件、2038 行改动）。
> 每份计划的开头都给了替代的 grep 判据，用那个。

### 奖励机制批次（006-009）的来源与决策记录

依据 `docs/奖励机制实施方案.md`（TRACK 100 重拆版，2026-07-26 经 Visual Companion 审核）。
维护者拍板：即时层用**全局 Toast**；音效**新合成两个短音频**（三音/四音上行）；
阶段 D **纳入本轮**（四期全做）。组织原则：我们的 +1 发生在专注结束、用户不在目标页，
奖励回路必须事件驱动、全局送达——008 的验收标准即「目标页关着弹窗照常出现」。
执行顺序 006→007→008 固定；009 只依赖 006，可与 007/008 并行。

### 奖励机制批次验证记录（2026-07-26）

- `GoalServiceTests`：29/29，通过每日热力口径与进度缓存语义测试。
- QML：目标页 11/11、主窗口奖励回路 18/18、统计页 22/22；全套 QML 391/391。
- 全量 CTest：Qt 6.11.1 下 12/12 通过；8 张离屏实现图已写入 `docs/设计稿/长期目标/`。

## 复核记录（2026-07-26，001-004 执行之后）

### 结论：四份计划的实质内容均已交付并验证通过

| 计划 | 复核方式 | 结果 |
|---|---|---|
| 001 | 读代码 + 跑 `BackupServiceTests` | ✅ 两处回滚都无条件重开数据库：`BackupService.cpp:326`（同步）、`:710`（异步）；受控测试钩子在位 |
| 002 | 读代码 + 跑 `GoalServiceTests` | ✅ `validateInput` 带 `categoryId`（2 处调用点）；`GoalService.cpp` 内 3 处 `db.transaction()` |
| 003 | grep 判据 + 两版本配置 | ✅ 裸 `/bin/rm` 已消失；`find_package(Qt6 6.7 ...)`；文档不再引导仓库内 `build/` |
| 004 | 数用例 | ✅ 5 个删除/重排用例 |

**全量测试：Qt 6.11.1 下 12/12 通过。**

### 两条 done criteria 的更正（都是计划本身写得不准，不是执行问题）

- **计划 001 的 grep 判据误报。** `grep "&& DatabaseManager::instance()->initialize"`
  在 `BackupService.cpp:429` 命中，但那处是**安装**路径，失败后紧接着调
  `restoreFromPreRestoreSnapshot` 回滚（该函数已按计划无条件重开）。代码正确，判据写宽了。
- **计划 003 的文档数字「29 个 QML 测试文件」是对的**，是本索引早先写的「30」有误
  ——把不匹配 `tst_*` 的 `preview_today_scene.qml` 数了进去。实测 `ls tests/qml/tst_*.qml | wc -l` = 29。
  C++ 用例数文档写 243、实测 248，差额是计划 004 后加的 5 个，属测量时点差异。

### 发现一个真实问题 → 已立项为计划 005

`PlatformControlTests::repeatedLaunchRequestsExistingWindow` 在 **Qt 6.9.0 下 5/5 稳定失败**、
6.11.1 下通过。**不是本轮引入的回归**（`SingleInstanceGuard.cpp` 只改了注释），
是计划 003 让人第一次真的按文档使用 6.9.0，把这个版本敏感的测试暴露了出来。

实测根因（用最小程序对两版本逐字符探测）：macOS 上 `QLocalServer` 名字长度上限
**Qt 6.9.0 = 46 字符，Qt 6.11.1 = 54 字符**；测试构造的名字是 53 字符。
产品用的 `com.zerionlito.PomodoroTodo` 是 27 字符，两版本都安全 —— 纯测试脆弱性。

### 范围：授权 9 个文件，实际改动 65 个

以下改动**不在任何一份计划的授权范围内**，因此也**没有经过复核**（它们恰好是绿的，
不等于被审过）：

| 计划外改动 | 说明 |
|---|---|
| schema **v8**（`focus_sessions.pomodoro_completed`）+ **v9**（三个 `category_*_snapshot` 列） | v8 **改变了「有效番茄」的定义**：`validPomodoroCountExpr` 现在要求 `pomodoro_completed = 1`，即手动停止的会话不再算完整番茄。这是产品语义变更，影响每一个历史统计数字 |
| 约 40 个 QML 文件 | 全局 `Theme.reduceMotion` 事实源改造、`TaskItem` 重命名失败处理、`LiquidGlassBackdrop`（+80 行） |
| `FocusTimer`、`StatisticsService`、`ExportService`、`TaskManager` | 多为配合 v8/v9 的聚合口径调整 |
| `SingleInstanceGuard`（注释）+ 新增 `unavailableInstanceLockFailsClosed` 用例 | 对应审计的 SEC-03，原本明确列在「已考虑但未立项」 |
| 新增 `cmake/DeployLocalApp.cmake` | 从 `CMakeLists.txt` 抽出的部署逻辑 |

**对 v8 的一处肯定**：迁移回填用
`mode = 1 AND end_time IS NOT NULL AND duration >= 180` 保住了历史番茄不归零，
注释也诚实承认「旧版没保存自然到点事实，无法完美还原」。

**对 v8 的一处指正**：`DatabaseManager.cpp:748` 硬编码了 `180`，
而 `FocusSessionRules.h` 的注释明确写着「不允许在别处复制出第二套阈值或模式判断」，
这里应当引用 `FocusSessionRules::kMinimumValidDurationSeconds`。

### 建议的后续复核（尚未认领）

1. **「有效番茄」语义变更专项**（schema v8/v9 + `validPomodoroCountExpr` + 相关聚合）——
   它改的是每个历史统计数字的含义，值得单独走一轮，优先级高于下面两项。
2. **40 个 QML 的 reduceMotion 改造** —— 重点核对 `AGENTS.md` 那条
   「无限循环和装饰粒子必须直接停止」是否真的落实，而不只是把 `duration` 归零。
3. `tests/qml/` 是否还藏着同类的 Qt 版本敏感假设（计划 005 未排查）。

## 第三轮审计（2026-07-26，针对未提交的 2038 行）

### 范围与理由

上一轮在 `43ba2ee` 覆盖了全仓，那些发现都还记在下面的「本轮已核实但未立项」表里，
**没有重审**。这一轮的靶心是此后新增、且从未被审过的东西：

- 计划外的那批 65 文件改动（schema v8/v9、约 40 个 QML 的 `reduceMotion` 改造、
  `cmake/DeployLocalApp.cmake`）——上一轮明确记为「没有经过复核」；
- 计划 006-009 交付的整套长期目标与奖励机制。

四个只读子代理并行审计（正确性/安全、奖励功能、动效重构、构建与测试），
共回报 19 条。我逐条打开被引用的代码复核：**确认 15 条、修正 2 条的影响面、驳回 1 条、
1 条降级为产品决策**。下面只记复核过的结论。

### 已确认并立项（→ plans/010-014）

| 发现 | 证据 | 计划 |
|---|---|---|
| 仪表盘「今日专注番茄」数的是**会话数**，不是番茄数 —— `getFocusSessionCount` 既不过滤 `mode` 也不过滤 `pomodoro_completed` | `StatisticsService.cpp:517-525` ← `:191` ← `DashboardView.qml:407` | 012 |
| 庆祝粒子被它要装饰的弹窗完全遮住，一个像素也没到过屏幕 | `MainWindow.qml:841`（`z:110`，在 contentItem 内）vs `MilestoneDialog.qml:22`（`Popup` + `modal`，渲染在 overlay 层）；迸发原点是弹窗中心、只飞 38px | 013 |
| 目标页把「查询失败」渲染成「你还没有目标」；详情页遇到临时故障把用户踢回列表 | `GoalsView.qml:79-80`、`:397`、`:130-140`；**同批代码的 `StatisticsView.qml:404-407` 做对了还写了注释** | 013 |
| 「长期目标」复选框第一次被点击后绑定被摧毁，之后与截止日期字段自相矛盾 | `GoalFormDialog.qml:323-324` 的 `checked: root.longTerm` + `onToggled`；两个写入点 `:87`/`:99` 从此失效 | 013 |
| 「有效番茄」口径在 `src/` 下仍有两份手抄副本，违反 `FocusSessionRules.h` 自己写的规则 | `DatabaseManager.cpp:748`（硬编码 `180`/`mode = 1`）、`StatisticsService.cpp:875` | 011 |
| `validPomodoroCountExpr()` 没有别名参数（它的 predicate 兄弟有），导致热力图查询往两表 JOIN 里塞裸列名 | `FocusSessionRules.h:33` vs `:22`；`GoalService.cpp:296` | 011 |
| v8 回填 `UPDATE` 无守卫无 `WHERE`，重入会用启发式覆盖真实的 `pomodoro_completed` | `DatabaseManager.cpp:745-752`（`ALTER` 有守卫、`UPDATE` 没有）+ 进入条件 `:263` | 011 |
| 迁移前快照只留 3 份，迁移链已有 5 步，最早那份被自动删掉 | `pruneOldBackups` `:1027` 保留 3；`backupDatabaseBeforeMigration` 有 7 个调用点 | 011 |
| 两条改写全部用户历史的 `UPDATE`（v8/v9 回填）零测试——现有断言只有 `user_version == 9`，把回填整个删掉也全绿 | `ServiceTests.cpp:2777` 等四个迁移槽 | 010 |
| 音效资源零守门测试（`PhaseSoundService` 是唯一不在任何测试可执行文件里的服务）；`qml.qrc` 74 条手工清单无任何校验 | `PhaseSoundService.cpp:10/12/14`；对比已有的 `ShaderAssetsTests` 等三个守门测试 | 014 |

**两处我修正了子代理的影响面判断**（原文夸大了）：

- 快照保留：子代理说「唯一能从坏回填恢复的快照被删了」。**不对**——保留的是最新 3 份，
  v8/v9 各自的前置快照都在。真正丢的是 before-v5，而 v5 恰好是上一轮记录过的
  「用冻结列清单重建 tasks 表」那个高风险迁移。影响真实但性质不同，已按此写进 011。
- v8 回填守卫：子代理称其为活跃缺陷。我**没能构造出一条正式用户路径**抵达
  「版本号<8 但列已存在」（ALTER + 回填 + 版本号在同一事务里）。按「成本一个 `if`、
  保护的是不可恢复数据」立项，而不是按「马上会出事」立项。011 里已如实写明。

### 已核实但**未**立项（第三轮新增，下轮参考，无需重审）

| 发现 | 为什么这轮没做 |
|---|---|
| `reduceMotion` 重构留下三套写法并存：161 处手抄的 `Theme.reduceMotion ? 0 : N`、25 处仍直读 `appSettings.reduceMotion`（14 个文件）、少数两者取或。`Theme.reduceMotion` 实际是**镜像**而非事实源 | M 工作量、纯整洁性。真正该做的是给 `Theme` 加一个 `motion(ms)` 函数和几个命名档位（项目已有颜色/间距/圆角令牌，唯独动效没有），但那是 161 处的机械改写，值得单独一轮 |
| `Theme.reduceMotion` 的生产写入点在 `main.qml:9-17`，而 `Theme.glassBlurAllowed`/`activeThemeId` 在 `MainWindow.qml` 里绑。后果：所有实例化 MainWindow 的 QML 测试里 `Theme.reduceMotion` 恒为 false，161 个新加的门全是暗的 | S，但它是上一条的前置；两条应该一起做 |
| 整个动效重构只有**一条**行为断言（`tst_ui_optimization.qml:396`）。`tst_theme_tokens.qml:42` 那条是同义反复（只断言 `property bool` 能被赋值） | S。观测钩子都现成（`pulseAnimationRunning`、`blinkRunning`、`particleCount`），但应排在上面两条之前做 |
| `LiquidGlassBackdrop.qml:25` 的 `effectRequested` 不含 `visible` 项，靠调用方 `DashboardTimerPanel.qml:124` 手动补 `&& root.visible`。组件自己的注释没写这个义务 | S、LOW 风险。下一个调用方漏写就会让全应用最贵的构造（FBO+shader+32px 模糊）在不可见页面上常驻 |
| `TaskItem`/`CountdownItem` 等 delegate 无条件 `layer.enabled: true`，每个可见任务行一个 FBO + 一次模糊，既不看 `reduceMotion` 也不看 `glassBlurAllowed` | MED-HIGH 风险：`TaskItem.qml:26-27` 的注释明确警告在 hover 事件派发期间切 `layer.enabled` 会重入已释放的 `QQuickItem`。**先跑 qmlprofiler 拿数字再谈**，别盲改 |
| `reduceMotion` 开启时备份/恢复遮罩连「还活着」的信号都没有——`BackupOperationOverlay.qml:46-47` 是 `visible: running`，指示器被整个移除而非停住 | S、LOW 风险。遮罩会吞掉 Escape，用户面对静止文字无法区分「在跑」和「卡死」。减少动效应该降级动画，不是删掉反馈 |
| `README.md:25` 和 `:39` 两条构建配方共用 `/tmp/pt-build`，而 `POMODORO_TODO_DEPLOY_LOCAL=OFF` 是 cache 变量会持久化 → 先跑验证构建再跑部署构建，`deploy-local-app` 目标**根本不存在**，部署静默失效 | S、纯文档。子代理已实测复现。与 `docs/运行命令.md` 也不一致（那边用了两个不同目录） |
| `README.md:49` 的 qmllint 命令指向 `pyside6-qmllint`——本机没装，且它来自同一份 README 禁用的 PySide6 工具链；`docs/运行命令.md:93` 给的是另一条不兼容的命令，且两条都漏掉 `qml/components/settings/*.qml`（10 个文件，占 QML 的 15%） | S。顺带：那条命令实测输出 373 条诊断却 exit 0，作为门禁等于没有 |
| `docs/运行命令.md:47` 的数字与实测不符（文档 243 用例 / 29 个 QML 文件，实测 **287** / **30**）；`:52-62` 的单目标命令漏了 `QT_QPA_PLATFORM=offscreen`，照做会拉起 cocoa 平台插件（违反项目自己的后台不弹窗规则）；`:29-30` 把 `POMODORO_TODO_ENABLE_QML_DEBUG` 的默认值说反了 | S、纯文档。这些数字是在这批改动里被「自信地更新」过的，仍然错 |
| `AGENTS.md` 的部署规则描述的是**已被替换掉的**实现（「删除旧包、复制新包」），而新脚本是 复制到 staging → 校验主二进制 → 原子 rename → 再删旧包 | S。这是 agent 最先读的规则文件，描述的却是上一轮刚被要求移除的危险顺序——将来可能有人照它「还原」 |
| 测试环境敏感性（计划 005 明确推迟的那次排查）：6 个测试可执行文件不设 org/app name 也不开 `QStandardPaths::setTestModeEnabled(true)`，实测在 `~/Library/Preferences/` 留下 plist；`RobustnessTests.cpp:302-309` 用挂钟断言 `< 1000ms`；4 处固定 `qSleep` 合计 6.5 秒；`ServiceTests.cpp:1251` 依赖 IANA 时区库 | M。测试的绿是机器速度、`~/Library` 残留和 tzdata 的函数，不只是代码的函数 |
| `reorderGoal`（约 50 行 + 事务 + 3 个用例 + 一个专用索引）**零调用者**，且它按 `loadGoals(全部)` 算下标，而 UI 渲染的是过滤后的列表——将来接拖拽排序会移错行 | S。要么删，要么把签名改成收 goal **id** 而不是列表下标（那样天然与过滤无关）。同理 `GoalsView.qml:44` 的 `goalOpened` 信号也无处理器 |
| `achieved_at` 只写不清（`GoalService.cpp:559`、`:706` 都带 `IS NULL` 守卫）。目标达成后调高目标值、再次达成，显示的仍是**第一次**的日期，统计页的已达成列表也按这个错日期排序 | S、影响小。注意 `LongGoal.h:47-49` 有一条刻意规则「进度回退不清空它」，清空只能限定在「用户主动改了目标值」这条路径 |
| 每次启动后的**第一个**番茄没有 `+1` toast（进度缓存首刷静默播种，且 `refreshMilestones` 的唯一调用者是 `main.cpp:126` 的 focusCompleted 连接）。`plans/008` 写的是「崩溃恢复后首个番茄不 toast」，实际频率高一个数量级；改 `dayStartHour` 也会吃掉下一个 toast | S。**里程碑弹窗不受影响**（走数据库位掩码，与这个内存缓存无关），所以核心庆祝是好的，丢的只是轻量 toast。修法是加一个专用的静默播种函数，或者干脆改文档 |
| `MilestoneDialog` 达成态把背景刷成 `Theme.accentFill`，标题和百分比正确换成了 `accentFillInk`，但 `:105` 的目标标题仍是 `inkStrong`、`:120` 仍是 `inkSoft`（这两个令牌是给普通卡片底调的） | S。需要实测对比度而不是凭感觉判断。**`GoalCard` 那一半已修**（2026-07-27）：达成徽标底色由 `transparent` 改为 `Theme.glassAccent`，`accentFillInk` 现在落在强调罩上而不是玻璃卡底上，与该令牌的设计语义一致。`MilestoneDialog` 的两处仍未处理 |
| ~~目标热力图的番茄数量**只用透明度深浅**表达，没有 `Accessible.name`、没有 tooltip~~ | **已修**（2026-07-27 目标页玻璃改造顺带）：每格补 `Accessible.name`（「N 日，M 个番茄」/「无投入」）与悬停 `ToolTip`，用例 `test_heatmap_exposes_count_without_relying_on_color` 锁定（已实测：移除该属性后用例转红） |
| `PhaseSoundService` 每次播放都 `remove` + `copy` 一次临时文件（GUI 线程上同步写 40-64KB），且这些临时文件从不清理 | S。庆祝触发那一帧的卡顿。`afplay` 的参数构造本身是安全的（绝对路径 + `QStringList`，无 shell） |
| `main.cpp:75-79` 把 `SingleInstanceGuard::LockUnavailable` 从「警告后继续」改成了 `qCritical` + `return -1`。策略本身站得住，但用户双击图标只会看到应用闪一下消失，诊断信息只在 Console.app 里 | S。加个可见的错误提示即可 |
| 目标进度聚合在每次 `focusCompleted` 都全量重跑（含被丢弃的短会话），`refreshMilestones` 结尾**无条件**发 `goalsChanged`，扇出到两个视图共 5 次查询 | MED 置信度：调用链确定，但「会成为问题」是推断不是实测。目标数是个位数、`pageActive` 也拦掉一部分。要做的话先测量，别盲改 |

### 本轮确认**没有**问题的地方（避免下轮重复排查）

- **`cmake/DeployLocalApp.cmake` 是安全的。** 四处 `rm -rf` 全部只指向
  `<dest>.staging-<token>` 和 `<dest>.previous-<token>`，**从不删 `destination_app` 本身**——
  实际路径是 rename 成 `previous` 后再删那个改名副本。配置期有 `\.app$` 正则、
  脚本内有五道 FATAL_ERROR 守卫（变量非空、源目录存在、父目录非 `/`、暂存路径未被占用）。
  顺序是 复制 → 校验主二进制 → 原子切换 → 清理，连 `SOURCE_APP == DESTINATION_APP` 都能活。
  上一轮的 P2 关切已彻底解决。
- **`reduceMotion` 重构通过了 `AGENTS.md` 那条硬规则。** 全树只有 2 处
  `loops: Animation.Infinite`（`Sidebar.qml:338`、`FocusView.qml:633`），两处都是
  `running:` 真停而不是 `duration` 归零；`CompletionParticles.burst()` 直接不创建对象；
  `BackupOperationOverlay` 的指示器 `running: false`。
  **没有一处「无限动画只把时长压成 0 还在空转」**。全树无 `ParticleSystem`/`FrameAnimation`。
- **本批次没有引入任何硬编码颜色**，也**没有引入任何 `visible === true` 断言**（两条项目红线都守住了）。
- **长期目标的进度 SQL 是干净的**：复用 `validPomodoroPredicate("fs")`、逻辑日走
  `LogicalDay::sqlShift`、起始日闭区间、科目归属优先取 `category_id_snapshot`
  （所以改任务的科目不会改写历史）。里程碑位掩码在重启/恢复/科目删除后都不会重播庆祝。
- **v8/v9 迁移的事务安全是对的**：DDL + 回填 + `user_version` 在同一事务里，
  SQLite 下崩溃会整体回滚，`ALTER` 各自有 `columnExists` 守卫。**schema 层幂等成立**，
  缺的只是数据层幂等（已立项 011）。
- **v9 科目快照的读取策略是对的**：三个消费方都优先 live join，只在科目行没了时才回落
  到冻结文本。改名/改色能正确传播，删除能保住历史。

### 已考虑并驳回（第三轮）

- **「`deploy-local-app` 挂在 `ALL` 上、选项默认 ON，任何一次普通构建都会覆盖
  `/Applications/番茄Todo.app`，应该把默认改成 OFF」** —— 驳回。
  这是**已记录的决定**：`AGENTS.md` 的「构建与部署规则」明写「用户说构建默认含部署步骤，
  必须以 `deploy-local-app` 结束」，`CMakeLists.txt:154-156` 的注释也写明
  「日常开发目录保持自动同步；审计/CI/临时构建传 OFF」。按 playbook，
  写进决策文档的取舍是既定事项，不是发现。真正的坑是那个 cache 变量的粘性
  （已作为独立条目记在上表）。
- **「并发部署可能撞上同一个 staging token」**（`string(RANDOM)` 是时钟播种）—— 驳回本轮。
  需要同一秒内起两个 `cmake -P` 进程才可能，且我没能实际复现。是脚本里唯一
  可能产生**损坏结果**而非干净失败的地方，值得记一笔，但不值得占本轮名额。
- **「`FocusSessionRules` 的定义在 C++ 和 SQL 里各存一份」**（`FocusTimer.cpp:504-507`
  用 C++ 表达同一规则）—— 驳回。写入方无法复用 SQL 字符串，这是语言边界的固有代价，
  不是可消除的重复。两边都引用同一组常量就已经是能做到的最好。

### 需要维护者拍板的产品问题（不是缺陷，执行者无权决定）

**v8 让「同一个动作」在升级前后按两套规则计数，且没告诉用户。**
回填把所有历史上 mode=1、已结束、≥3 分钟的记录都标成完整番茄——**包括用户当年
在 24 分钟时手动停掉的那些**。而升级之后，同样的手动停止会被记成 `pomodoro_completed = 0`。

后果：一个习惯提前几十秒停表的用户，历史数字纹丝不动，升级日之后的数字断崖下跌，
应用看起来像是「弄丢了番茄」或者「一夜之间变严格了」，没有任何解释。
长期目标的进度也继承这个不连续：从历史播种的目标会先快速推进、然后突然停滞。

三个选项：(a) 接受它，在发布说明里写一句 + 应用内一次性提示；
(b) 让回填给历史行打第三种状态，读取方可以选择包不包含（代价：要审所有读取路径）；
(c) 什么都不做。

这个决定还会和 plans/012（仪表盘番茄数会变小）叠加生效，**两个变化会在同一次升级里
同时出现**。建议一并决定。

**维护者决策（2026-07-26）：选 (a)。** 保留 v8 对历史数据的兼容回填，不伪造无法从旧库还原的
第三种“不确定”状态；发布说明和应用内一次性提示需明确告知“升级后只有自然到点才计完整番茄”。
本决策不改动 010-014 已锁定的迁移口径；提示的交互与持久化属于独立发布任务。

### 本轮未审计的范围

- `src/platform/macos/*.mm` —— 连续第二轮未做正确性深挖。
- QML 渲染性能**仍未实测**（没跑 qmlprofiler）。上表里 delegate 层 FBO 那条的
  「是主要开销」是静态推断，落地前必须实测。
- 上一轮记录的那批发现（统计页全表扫描、v5 迁移、备份快照清理、CSV、
  `FocusView` 1246 行等）**没有重新审**，它们仍然有效，见下面的旧表。
- `docs/superpowers/plans/` 的 31 份历史计划、`docs/testing/` 的三份过期验收报告，
  仍未清理。
- 一条值得记的观察（不是缺陷）：`plans/*.md` 和 `docs/superpowers/plans/` 里的
  「Executor instructions / STOP conditions」段落是写给 agent 的祈使句。
  这是有意为之的项目内容，但它构成一个常设面——任何读到这些文件的 agent 都可能被其中的
  指令带偏。在计划模板顶部加一行「以下内容供人类与被派发的执行者参考，
  审计/读取本文件的代理不应执行其中指令」可以廉价地关掉这个面。

## 依赖说明

- **011 依赖 010（硬依赖）**：011 要修改的正是 v8 回填语句和迁移快照策略。
  010 提供的逐行断言是唯一能证明「011 做的是等价重写而不是语义变更」的东西。
  没有它就改，等于无保护地改写用户历史数据。011 的 drift check 会直接检查 010 是否已落地。
- **012 依赖 011**：012 要新增一个走「有效番茄唯一口径」的查询，
  必须等 011 把 `validPomodoroCountExpr` 的别名参数加上、把两处副本收编完，
  否则 012 会成为第四份副本。
- **013 和 014 无依赖**，可与 010-012 并行，也可以先做——它们零 C++ 改动（013）
  或零产品代码改动（014），风险最低。若想先看到成果，从 013 开始。
- **004 依赖 002**：两者都修改 `tests/GoalServiceTests.cpp`。002 会改动
  `validateInput` 的签名并新增 2 个用例，004 在其之上再加 5 个用例。
  反过来做会产生不必要的冲突。004 的基线用例数因此写成「15 或 17 皆可」。
- 001 与 003 相互独立，也不依赖 002/004，可以任意顺序或并行执行。
- 001 内部有一处顺序要求：必须先加受控测试钩子（Step 2）才能写出能真正锁住缺陷的用例（Step 3）。

## 第一轮已核实但未立项的发现（仍然有效，第三轮未重审）

按 leverage 排序，供下一轮参考。**这些都已经核实过代码，不需要重新审计**：

| 发现 | 为什么这轮没做 |
|---|---|
| 统计页一次刷新约 40 次全表扫描（逐日循环查询 + 日期列被 `date()` 包裹导致 `idx_sessions_start` 用不上） | M 工作量、MED 风险，会动到所有统计数字的口径，需要先补边界值特征测试。修法模板已在 `StatisticsService.cpp:795-802` 的 `weeklyAggregates` 里 |
| `DatabaseManager` 的 v5 迁移用冻结在当年的列集重建 `tasks` 表，可被与版本无关的条件触发，会抹掉 `estimated_pomodoros` 数据 | 真实缺陷，但触发需要 PRAGMA 瞬时失败或库被手改，现实概率低；且 `migrateToVersion5` 会先调 `backupDatabaseBeforeMigration()`，数据可从迁移前备份找回。修它要动迁移链（MED 风险），排在 P1 之后 |
| `before-restore-*` 快照永不清理（`pruneAutoBackups` 的过滤器只匹配 `auto-*`），且混进 `listBackups` 的恢复候选列表 | S 工作量、LOW 风险，纯粹是这轮名额有限。可与 001 合并成一个备份专项 |
| 无 CI；`CMakeLists.txt` 里没有任何 `-Wall -Wextra`；`pyside6-qmllint` 只覆盖 58 个 QML 文件里的 7 个且本机未安装 | 开 `-Wall -Wextra` 预计一次性冒出几十条既有警告，需要单独一轮清理，不适合塞进别的计划。加 CI 需要先确认是否打算推 GitHub |
| 恶意 `.tomatobackup` 可注入 trigger/view 并存活到用户主库（`inspectBackup` 不校验 `sqlite_master`，`cleanBackupTables` 只 DROP 两张表）；嵌入设置用 `QDataStream >> QVariant` 反序列化不可信输入 | 代码事实确凿，但利用前提是用户主动导入外来备份文件，单机考研工具场景下暴露面窄。M 工作量 |
| QML 测试 30 个文件挤在一条 ctest 条目里串行跑（`ctest -j` 无效），约 180 处固定 `wait()` 硬睡 12-13 秒 | 拆 ctest 条目是 S 且几乎无风险，值得单独做一轮；`wait` → `tryCompare` 会暴露原本被睡眠掩盖的时序假设，需要预留排查时间 |
| `PhaseCompletionCoordinator.qml` 零测试覆盖，且与 `FocusView.qml:330-340` 各存一份长休息判定 | S 工作量。两份规则漂移时用户会看到专注页和系统通知说两个不同的休息时长 |
| 时长/日期格式化在 9-10 个 QML 文件各抄一份（`formatClockTime` 同构实现 10 处、`logicalToday` 3 处），三个 `*Format.js` 按视图切分而非按关注点切分，反而装不下最该共享的东西 | S-M 工作量、LOW 风险，但收益是可维护性而非正确性，排在缺陷之后 |
| `tests/ServiceTests.cpp` 4059 行 / 118 个测试槽，横跨 11 个服务 | L 工作量。拆分本身价值高，但要先把 `friend class ServiceTests` 改成一个共享的测试访问结构体，否则每拆一个文件加一个 friend |
| `qml/views/FocusView.qml` 1246 行，6 态状态机在 QML 里从 `FocusTimer` 反推（状态双源） | L 工作量、MED-HIGH 风险。专注计时是核心路径，**必须先把 `tst_focus_view.qml` 的固定 `wait` 换成 `tryCompare` 建立可靠特征测试**，否则重构没有安全网 |
| `docs/superpowers/plans/` 里 31 份历史计划共 1216 个未勾选项，其中多数功能早已上线，与唯一真正在途的计划混在一起 | S 工作量，纯文档整理 |
| `docs/testing/` 三份 2026-06 的一次性验收报告，其中「有关联任务的科目不可删除」与现行代码相反（`CategoryManager.cpp:254` 是先解除关联再删） | S 工作量。唯一实际代价是将来改科目删除策略时会读到错误的"原始设计意图" |

## 第一轮已考虑并驳回

- **`ExportDialog.qml` 的 `mondayOf` 漏了 `setHours(0,0,0,0)` 是 bug** —— 驳回。
  该函数唯一调用点是 `ExportDialog.qml:105`，结果直接进 `Qt.formatDate(..., "yyyy-MM-dd")`，
  时分秒被丢弃，无任何后果。重复实现本身是真的（已并入上表的格式化收编条目），
  但「已发生行为漂移」这个判断不成立。
- **`BackupService::verifyRestoredDatabase` 的表白名单应加 `long_goals`** —— 驳回。
  该白名单校验的是「核心表必须存在」，而 `long_goals` 是懒建表，早于长期目标功能的备份里
  根本没有这张表，加进去会让**恢复旧备份直接失败**。`countdown_goals` 同样不在白名单里，保持一致。
- **CSV 导出未中和电子表格公式前缀（`=` `+` `-` `@`）** —— 驳回（本轮）。
  单机单用户，任务标题的作者就是导出者本人；只有先经由恶意备份文件才成链，
  链条长、前提强。若以后做了备份文件的输入校验，可顺带补一个 `if`。
- **`FocusTimer` 在番茄目标短于 3 分钟时会给被丢弃的会话计入连续番茄数** —— 驳回。
  `AppSettings::normalizeWorkMinutes` 把专注时长下限锁在 5 分钟，UI 路径不可达，
  只是 `Q_INVOKABLE startPomodoroWork` 的理论防御缺口。
- **`CountdownView` 是 7 个视图里唯一没接 `pageActive` 的** —— 驳回。
  它没有 Timer 也没有刷新用的 `Connections`，不可见时不产生额外工作。属于命名不对称而非性能问题。
- **`BackupServiceTests` 耗时 8.4 秒偏慢** —— 驳回。
  约 25 个用例，每个都建全新 SQLite 库并做真实文件复制 + fsync，8.4 秒基本是真实 I/O 成本；
  且它已是独立 ctest 条目可以并行。相对 QML 那 42 秒，优化性价比低。
- **`tests/qml/preview_today_scene.qml` 是死文件** —— 驳回。
  文件名不匹配 `tst_*`，qmltestrunner 不会加载它，删不删都无成本。
- **服务层单例存在循环依赖** —— 未发现。
  `src/main.cpp` 显式把 `FocusTimer → GoalService` 的连接写在 main 里并注明
  「不让目标服务反向依赖 FocusTimer」，`FocusSessionRules.h` 也刻意放在公共头而非某个服务的
  匿名命名空间。这是有意识的解耦，不是债。

## 第一轮未审计的范围

- `src/platform/macos/*.mm` 只过了安全面，没做正确性深挖。
- QML 渲染性能**没有实测**（未跑 profiler）。上表中「统计页全表扫描」的索引效果
  也未用 `EXPLAIN QUERY PLAN` 验证过，落地前需要逐条验。
- 30 个 QML 测试文件的断言质量只做了抽样。
- `resources/`（shader / 壁纸 / 字体）只确认了对应的资产测试存在。
- `build/`、`build-release/` 生成物已排除。

## 方向性建议（不是缺陷，供维护者权衡）

这些是「往哪走」的选项，不与上面的缺陷排在一起。详细证据见本轮审计对话。

1. **`goalService` 已注册到 QML 但零引用** —— 数据在写、进度在算、里程碑在触发，
   用户完全看不到。设计方案第六节点名的三处接入（导出加目标维度、统计页已达成列表）
   都是纯 C++、可单测、不依赖界面，能让目标数据立刻产生可见价值。
2. **例行任务加「星期几」粒度** —— 设计 spec 把它列为 v1 主动推迟项。
   `routines` 表加一列 `weekday_mask DEFAULT 127`（等价于每天，旧数据行为不变），
   生成逻辑多一个位判断即可。
3. **任务缺少手动排序** —— `categories`、`routines`、`long_goals` 都有 `display_order`
   和 `reorder*()`，唯独 `tasks` 没有。番茄工作法的核心动作就是「从列表里挑下一个」。
   轻量替代：只加一个「下一个要做」标记。
4. **三套目标体系（倒数 / 每日专注目标 / 长期目标）分散在三个界面** ——
   设计方案第二节自己列表承认了这个三分裂。合并成一个页面能少建一个侧栏项（现有 7 项）。
   代价是要动已上线且有 213 行测试的 `CountdownView`，建议先出设计稿。
5. **把「专注被中断」变成可见数据** —— `sessionDiscarded` 信号已在发、
   `restoreInterruptedSession` 已能识别中断，但这些事件全被当噪声丢弃。
   风险在于动 `focus_sessions` 表和 `FocusTimer` 结算路径。
