# Plan 038: 新恢复点提交成功后再清理旧快照

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按步骤执行并验证。遇到 STOP condition 停止，不自行扩大改动。
> 完成后更新 `plans/README.md` 中本计划状态。
>
> **Drift check（先跑）**：
> `git diff --stat f8e3120..HEAD -- src/services/BackupService.h src/services/BackupService.cpp tests/BackupServiceTests.cpp`
> 若恢复前快照创建、异步 preflight 或 retention 逻辑已变化，逐段重核后再执行。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW-MED
- **Depends on**: none
- **Category**: data safety
- **Planned at**: commit `f8e3120`，2026-08-16

## 产品口径

清理旧恢复点的前提是：本次新的 `before-restore` 快照已经原子创建成功。
源备份预检失败、复制失败或快照写入失败时，旧恢复点数量必须完全不变。

短时间多占一份数据库副本是可接受成本；先删旧快照再赌新快照能写成功，会主动降低故障恢复能力。

## Current state

### 同步路径先 prune 再写（`BackupService.cpp:508-518`）

```cpp
pruneBeforeRestoreBackups();
const QString preRestorePath = ...;
emit restoreStarted();
if (!writeSnapshot(preRestorePath, QStringLiteral("before-restore"))) {
    emit restoreCompleted(false, ...);
    return false;
}
```

### 异步路径甚至在外部文件预检前 prune（`BackupService.cpp:696-713`）

```cpp
if (!QDir().mkpath(autoBackupsDir())) { ... }
pruneBeforeRestoreBackups();
auto context = QSharedPointer<RestoreContext>::create();
...
setBusy(true, QStringLiteral("正在校验恢复文件"), true);
emit restoreStarted();
```

preflight 在后台复制和校验外部源；失败分支 `:724-728` 直接返回，不补新快照。

### helper 明确只保留 N-1（`BackupService.cpp:965-969`）

```cpp
void BackupService::pruneBeforeRestoreBackups() const
{
    pruneByPrefix(kBeforeRestorePrefix, kBeforeRestoreRetention - 1);
}
```

现有 `repeatedRestoresCapPreRestoreSnapshots()` 只覆盖成功恢复后的最终数量，无法抓住失败时少一份。

## Scope

**In scope**：

- `src/services/BackupService.h`
- `src/services/BackupService.cpp`
- `tests/BackupServiceTests.cpp`
- `plans/README.md`（只更新状态）

**Out of scope**：

- 不改变 `kBeforeRestoreRetention` 的值。
- 不改变自动备份 `auto-` 的独立配额。
- 不修改备份格式、恢复安装或回滚协议。
- 不处理备份资源预算和 Schema 全量校验；两者是独立 backlog。

## Implementation

### Step 1: 先写能击穿当前实现的异步失败测试

在 `BackupServiceTests.cpp` 新增
`failedAsyncPreflightKeepsAllPreRestoreSnapshots()`：

1. 在测试备份目录铺好恰好 `kBeforeRestoreRetention` 个不同文件名的
   `before-restore-*.tomatobackup`。
2. 创建一个明确损坏的外部源文件。
3. 对 `restoreCompleted` 建 `QSignalSpy`，调用异步 `requestRestore()`。
4. 等到失败信号，断言 success 为 false。
5. 重新列目录，断言原有文件名集合和数量完全不变。

旧实现会在 preflight 前删到 N-1，这条测试应先转红。不要只断言“仍有文件”，必须比较完整集合。

**Verify**：运行 `~/pt-audit/BackupServiceTests failedAsyncPreflightKeepsAllPreRestoreSnapshots`
→ 旧实现稳定失败，差异是少了一份既有快照；不是超时或随机失败。

### Step 2: 改正 helper 的语义和注释

`pruneBeforeRestoreBackups()` 改为保留完整的 `kBeforeRestoreRetention`，不再预留 N-1。
同步更新 `BackupService.h` 和实现注释：helper 的调用前提是新快照已经成功存在，它负责把临时的 N+1 收敛回 N。

函数名可保留，避免无意义扩散；如果改名为 `pruneCompletedBeforeRestoreBackups()`，必须一次更新全部调用与测试，
不能同时留下两种含义。

**Verify**：`rg -n "kBeforeRestoreRetention - 1|pruneBeforeRestoreBackups" src/services/BackupService.*`
→ 前一个模式 0 命中；helper 及调用位置与新“成功后清理”语义一致。

### Step 3: 同步恢复改成“写成功后清理”

移除 `restoreBackup()` 写快照前的 prune。只有 `writeSnapshot(preRestorePath, ...)` 返回 true 后才调用 helper，
然后再关闭数据库并执行恢复。

若快照失败，立即返回且旧快照零变化。若后续恢复失败，新快照仍作为回滚/人工恢复依据保留，数量已收敛到 N。

**Verify**：`cmake --build ~/pt-audit -j8`
→ exit 0，无新增 warning；同步恢复既有测试通过。

### Step 4: 异步恢复按实际快照存在性清理

移除 `requestRestore()` 在 preflight 前的 prune。

异步 worker 当前把“创建快照 + 原子安装”合成一个 `OperationResult`。原子安装可能失败，但快照已成功生成；
这时也应保留新快照并收敛配额。为此在 `BackupService.cpp` 的匿名命名空间增加内部结果结构，
同时携带 `OperationResult operation` 和 `bool snapshotCreated`；把该阶段的 watcher 改为这个结果类型：

- `createSnapshot` 成功后、执行 `atomicCopy` 前，把 `snapshotCreated = true`。
- finished 回调只在该标志为 true 时调用 prune helper，然后按 `operation.success` 走原有成功/失败分支。
- preflight 阶段不创建快照，因此完全不触发该 helper。

不要只用 `QFileInfo::exists(preRestorePath)` 猜成功：毫秒时间戳理论上可能撞到既有路径，文件存在不等于本次创建成功。
布尔标志随 future result 按值返回，没有跨线程共享写；清理仍在 GUI 线程回调，避免并发修改同一目录。

**Verify**：运行新增失败用例
→ preflight 失败后原文件名集合完全相等；运行 `repeatedRestoresCapPreRestoreSnapshots`
→ 成功路径最终恰为 N。

### Step 5: 保留成功路径配额测试并补边界

继续运行 `repeatedRestoresCapPreRestoreSnapshots()`，它必须仍为 N。
再让失败测试的初始数量改成 N+2，验证预检失败仍**不清理**任何文件；预检尚未创建新恢复点，不能借失败操作顺便做 housekeeping。
如果测试套件不希望一个函数覆盖两组数据，拆为 data rows。

**Verify**：运行 `ctest --test-dir ~/pt-audit -R '^BackupServiceTests$' --output-on-failure --timeout 240`
→ 全组 0 failed，两组失败前集合断言和成功配额断言都通过。

## Test plan

- 沿用 `repeatedRestoresCapPreRestoreSnapshots()` 直接铺历史文件的快速模式，不用秒级时间戳 sleep。
- 新增恰好 N 与 N+2 两组 preflight 失败数据；均比较文件名集合，不只比较数量。
- 保留成功恢复创建快照、成功多次恢复收敛配额、auto 前缀不受影响的既有覆盖。

## Verification

```bash
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build ~/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit -R '^BackupServiceTests$' --output-on-failure --timeout 240
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8
```

预期：备份定向测试与全量测试通过；无残留 `.staging-*`；不启动 GUI。

## Done criteria

- 异步外部源预检失败前不再删任何旧恢复点。
- 同步/异步快照创建失败时旧集合保持不变。
- 新快照创建成功后，最终数量稳定收敛到 `kBeforeRestoreRetention`。
- 自动备份配额完全不受影响。
- 回归测试在旧实现上能稳定转红，不依赖 sleep。

## STOP conditions

- worker 结果无法可靠区分“快照成功、安装失败”和“快照本身失败”；不能退回文件存在性猜测。
- 服务允许两个恢复任务并发；当前按目录和路径存在性判断就不再安全，需要先建立操作串行化。
- 新快照成功后 prune 失败需要升级为“整个恢复失败”的产品决策；当前计划保持既有 best-effort 清理语义。

## Maintenance notes

- 所有 retention 清理都应遵守“新副本提交后再删旧副本”；新增备份类型时不要复制先删后写模式。
- reviewer 要特别检查异步失败分支：snapshot 已成功但 install 失败时仍应保留新快照并清理到 N。
- 资源预算另列 backlog；不要以“节省一次临时副本”为由恢复先 prune 的危险顺序。

## Git workflow

- 建议分支：`advisor/038-prune-restore-snapshots-after-create`
- 建议提交：`修复恢复失败前提前删除旧快照`
- 不 push、不创建 PR，除非维护者明确要求。
