# Plan 037: 统一导出关闭语义，并让“全部导出”读取同一个数据库快照

> **当前状态（2026-09-05）**：已完成并纳入当前分支；提交证据见 [状态索引](README.md)。下文的执行步骤、旧基线及未勾选验收项均为历史记录，不代表待执行；本轮全量验证 70/70 通过。

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 完整读完再执行。逐步验证；命中 STOP condition 时停止并汇报。
> 完成后更新 `plans/README.md` 中本计划状态。
>
> **Drift check（先跑）**：
> `git diff --stat f8e3120..HEAD -- src/services/ExportService.h src/services/ExportService.cpp qml/components/ExportDialog.qml tests/ServiceTests.cpp tests/qml/tst_phase3_export_ui.qml`
> 若导出线程、busy/关闭协议或两文件提交逻辑变化，先重核计划。

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: 032、033（均 DONE）
- **Category**: correctness / UX contract
- **Planned at**: commit `f8e3120`，2026-08-16

## 产品口径

1. 当前没有真正的工作线程取消协议，所以导出进行中不能提供“点了按钮就像取消了”的假行为。
   Escape、点击外部和“取消”按钮必须一致：busy 时都不能关闭；结束后都可关闭。
2. “全部导出”产生的任务 CSV 与专注 CSV 是一个逻辑导出包，必须来自同一 SQLite 读快照。
   文件层的原子替换只能保证“两份一起换”，不能保证两次查询看到的是同一个时间点。

## Current state

### 关闭策略只挡 Escape/外部点击

`ExportDialog.qml:36-42` 已在 busy 时使用 `Popup.NoAutoClose`，但 `:340-345` 的按钮仍无条件关闭：

```qml
Button {
    text: qsTr("取消")
    onClicked: root.close()
}
```

这不是“取消任务”，只是把进度窗口藏掉。用户会误以为导出停止，后台仍继续写文件。

### “全部导出”实际是两个独立数据库读取

`ExportService.cpp:390-403`：

```cpp
if (!exportTasksToFile(startDate, endDate, stagedTasksPath, false, workerDatabasePath)) {
    return false;
}
if (!exportFocusSessionsToFile(startDate, endDate, stagedSessionsPath,
                               false, workerDatabasePath, dayStartHour)) {
    QFile::remove(stagedTasksPath);
    return false;
}
```

`exportTasksToFile()` 与 `exportFocusSessionsToFile()` 各自调用 `acquireDatabase()`，各自 count/query/release。
两者之间若主线程提交新专注记录，任务 CSV 与专注 CSV 会分属不同时间点。

`commitExportPair()` 只负责暂存文件与旧文件的原子替换/回滚，这一层应保留。

## Scope

**In scope**：

- `src/services/ExportService.h`
- `src/services/ExportService.cpp`
- `qml/components/ExportDialog.qml`
- `tests/ServiceTests.cpp`
- `tests/qml/tst_phase3_export_ui.qml`
- `plans/README.md`（只更新状态）

**Out of scope**：

- 不实现真正的线程取消；那需要取消令牌、查询中断、暂存文件清理和完成信号新协议，应单独设计。
- 不切换生产数据库到 WAL。当前备份按单 SQLite 文件设计，WAL 是独立架构决策。
- 不改变 CSV 列、文件名、逻辑日边界和转义规则。
- 不重写 `commitExportPair()` 的文件原子性。

## QML 离屏测试红线（必须内联遵守）

- **禁止断言 `visible === true`。** 本项目用 `QT_QPA_PLATFORM=offscreen`，`visible` 会沿父级可见性链级联，
  不能稳定表达组件业务状态。改断言业务属性、控件 `enabled`、`Popup.opened`、模型内容或信号参数。
- **所有“今天/日期”都走逻辑日。** 使用测试现有的 `logicalDayService`、`logicalToday()` 或注入固定 ISO 日期；
  不直接用物理日 `new Date()` 推导今天，否则凌晨 `dayStartHour` 前会得到偶发失败。
- **不要等待或监听 `Popup.onClosed` 作为完成判据。** 离屏环境不保证投递该生命周期回调。
  直接调用被测请求/提交函数，并断言业务状态、`opened` 或控件状态；不要靠 `onClosed` SignalSpy 结束测试。

## Implementation

### Step 1: 先统一弹窗关闭语义

给 `tests/qml/tst_phase3_export_ui.qml` 的假 export service 增加 `busy` 属性；给取消按钮稳定的
`objectName`。增加测试：

- 调用 `open()` 后只用 `opened` 确认弹窗进入业务打开态，禁止断言 `visible`。
- `busy = true` 时断言取消按钮 `enabled == false`；对 disabled 按钮做鼠标点击后，
  断言 `opened` 仍为 true，不监听 `onClosed`。
- `busy = false` 后断言按钮 enabled；点击后断言 `opened == false`，不等待 `onClosed`。
- 保留现有 Escape/closePolicy 测试，确保三条退出路径语义一致。

实现选择最小方案：`enabled: !root.busy`。不要在没有后端取消协议的情况下把按钮改成“停止导出”。
如果 busy 时需要说明，可用 tooltip/辅助文本明确“导出完成后可关闭”，不要伪造取消结果。

**Verify**：运行 `ctest --test-dir ~/pt-audit -R '^QmlTest.phase3_export_ui$' --output-on-failure`
→ busy 时按钮 disabled 且 `opened` 不变；busy=false 后 `opened` 变为 false，整组 0 failed。

### Step 2: 抽出“使用既有连接写 CSV”的内部函数

在 `ExportService` 内把现有两个函数拆为两层：

- 外层 `exportTasksToFile(...)` / `exportFocusSessionsToFile(...)` 保持公共行为：校验、获取/释放连接、
  单文件成功信号。
- 内层 helper 接收 `const QSqlDatabase&`，执行现有 count、SELECT、QSaveFile 写入和进度逻辑，
  不获取连接、不开始嵌套事务。

两个 helper 必须继续复用现有 `finishCsvFile()`，保持 UTF-8、CSV 表头、错误消息和 QSaveFile 原子提交不变。
中文注释说明分层是为了让“全部导出”共享一个读事务，不是为了代码形式整洁。

**Verify**：`cmake --build ~/pt-audit -j8` 后运行
`ctest --test-dir ~/pt-audit -R '^PomodoroTodoTests$' --output-on-failure --timeout 240`
→ 既有单文件和全部导出测试仍全部通过，CSV 内容断言不变。

### Step 3: “全部导出”只获取一次连接并包一层读事务

`exportAllToDirectory()` 在目标路径预检完成后：

1. 调用 `acquireDatabase(workerDatabasePath, &ownedConnectionName)` 一次。
2. 在第一条业务 SELECT 前开始事务。
3. 用同一个连接依次调用任务、专注 helper，写入两个 staged 文件。
4. 任一查询/写入失败：rollback、清理已生成的 staged 文件、释放自有连接、返回 false。
5. 两份 staged 文件写完后 commit 读事务，再调用现有 `commitExportPair()`。
6. 所有 return 分支都释放工作线程连接，不能让 named connection 泄漏。

不要在 helper 内再次 transaction。SQLite 的一致快照在同一连接、同一显式事务的首次读取时确定；
两次独立只读连接不具备这个保证。

当前生产库是 rollback journal。长读事务可能让主线程提交等待，但计划 032 已为两侧设置 5000ms
`busy_timeout`。本计划不改变这个取舍。

**Verify**：`rg -n "acquireDatabase|transaction\\(|commit\\(|rollback\\(" src/services/ExportService.cpp`
→ `exportAllToDirectory` 只获取一次连接、只开一层事务，所有失败出口有 rollback/释放路径；随后 ServiceTests 通过。

### Step 4: 用确定性并发测试证明快照一致

在 `tests/ServiceTests.cpp` 增加 `exportAllUsesOneDatabaseSnapshot()`。禁止用 sleep 或概率竞争。

参照 `BackupService` 的一次性测试 hook 模式：

- `ExportService` 声明 `friend class ServiceTests`，增加只供测试使用、默认空的
  `std::function<void()> m_betweenExportFilesHookForTest`。
- hook 只在任务 CSV 写完、专注 SELECT 开始前调用一次；调用后立即清空，避免跨测试污染。
- 测试先把临时测试库切到 WAL（仅测试库），这样第二连接能在读事务存在时提交。
- 初始插入一条任务和一条专注记录；hook 从独立 named connection 插入并提交第二条专注记录。
- 调用同步 `exportAll()`。
- 断言数据库最终包含第二条记录，但导出的专注 CSV 不包含它；两份文件都只反映事务开始后的同一快照。

连接必须在创建它的线程/作用域内关闭，并在所有 `QSqlDatabase` 句柄销毁后再 `removeDatabase`。
测试结束恢复 hook 为空；临时库销毁即可清理 WAL 文件。

另保留并运行既有：

- `exportFocusSessionsAndExportAllWriteExpectedCsvFiles()`
- `exportAllRejectsInvalidDestinationBeforeReplacingFiles()`

**Verify**：运行 `~/pt-audit/PomodoroTodoTests exportAllUsesOneDatabaseSnapshot`
→ 0 failed；数据库含 hook 后写入行，但导出 CSV 不含该行。

### Step 5: 证伪新测试

临时让 `exportAllToDirectory()` 回到两个独立连接/事务，确认新并发测试转红；还原实现并 `touch`
被还原的源文件后重建，确认转绿。不要把证伪改动提交。

**Verify**：旧双连接结构下新用例失败；还原后同一命令 0 failed，`git diff` 不含证伪改动。

## Test plan

- QML：busy 期间按钮关闭被拒、busy 结束后关闭恢复；只断言 `enabled/opened`，不碰 `visible/onClosed`。
- C++：沿用 `ServiceTests::exportFocusSessionsAndExportAllWriteExpectedCsvFiles()` 的临时目录和 CSV 读取模式。
- 并发：只用一次性 hook + WAL 测试库建立确定时序，不用 sleep，不改变生产 journal mode。
- 回归：单文件任务导出、单文件专注导出、无效目标路径、两文件提交失败清理全部保留。

## Verification

```bash
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build ~/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^QmlTest.phase3_export_ui$' --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^PomodoroTodoTests$' --output-on-failure --timeout 240
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8
```

预期：UI 与 Service 定向测试通过，全量通过，无新增 warning。不要启动 GUI。

## Done criteria

- busy 时三种关闭入口一致，取消按钮不再制造“已经取消”的假象。
- `exportAll` 的两个查询使用同一连接、同一显式读事务。
- 文件对的现有原子替换和失败回滚不退化。
- 确定性并发测试能证明事务外后写入的数据不会只混进第二份 CSV。
- 单独导出任务/专注的公开行为与格式不变。

## STOP conditions

- 真实导出基准超过 5 秒，导致主线程写入稳定越过现有 busy_timeout；需要重新设计快照方式，不能盲目加长超时。
- `QSqlDatabase::transaction()` 在只读工作连接或目标 Qt SQLite 驱动上失败。
- 为共享连接必须跨线程传递 `QSqlDatabase` 句柄；这是 Qt 明确不允许的，需重构调用边界。
- 产品要求“取消”必须真正停止工作线程；应拆出完整取消协议，不在按钮层伪造。

## Maintenance notes

- 新增第三种“全部导出”文件时，必须加入同一连接/事务和现有文件对提交协议，不能再单独获取连接。
- reviewer 要检查每个提前 return 是否同时处理事务、staged 文件和 named connection，三者缺一都会留下状态。
- 真正取消导出明确延后；未来实现时必须让 busy、完成信号、QSaveFile 清理和退出守卫共享一个取消状态机。

## Git workflow

- 建议分支：`advisor/037-export-cancel-and-shared-snapshot`
- 建议提交：`修复全部导出快照分裂和忙碌时假取消`
- 不 push、不创建 PR，除非维护者明确要求。
