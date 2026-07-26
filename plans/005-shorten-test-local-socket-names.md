# Plan 005: 缩短测试用的本地套接字名，让测试套件在 Qt 6.7+ 全版本都能跑绿

> **Executor instructions**: 按步骤执行本计划。每一步都要运行验证命令并确认预期结果，
> 再进入下一步。若触发 "STOP conditions" 里的任何一条，立即停下来报告，**不要自行发挥**。
> 完成后更新 `plans/README.md` 里本计划的状态行（除非派发你的评审者说明由他维护索引）。
>
> **Drift check（先跑这个）**：
> `git diff --stat 43ba2ee..HEAD -- tests/PlatformControlTests.cpp`
> 若该文件有改动，先把下面 "Current state" 的代码摘录与实际代码逐行比对；
> 不一致就按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `43ba2ee`, 2026-07-26
- **备注**: 本计划修的不是产品代码缺陷，而是测试自身对 Qt 版本敏感。产品代码不受影响（原因见下）。

## Why this matters

`PlatformControlTests::repeatedLaunchRequestsExistingWindow` 在 **Qt 6.9.0 下 100% 失败**
（连续跑 5 次全失败），在 Qt 6.11.1 下通过。失败信息是：

```
QWARN  : 无法创建单实例召回通道: "QLocalServer::listen: Name error"
FAIL!  : PlatformControlTests::repeatedLaunchRequestsExistingWindow() Compared values are not the same
   Actual   (secondary.start())                             : SecondaryInstanceUnreachable
   Expected (SingleInstanceGuard::SecondaryInstanceNotified): SecondaryInstanceNotified
```

**根因已实测确认，不是猜测**：macOS 上 `QLocalServer` 的名字长度有上限，且**上限随 Qt 版本变化**。
用一个最小程序对两个 Qt 版本逐字符探测得到：

| Qt 版本 | `QLocalServer::listen()` 能接受的最大名字长度 |
|---|---|
| 6.9.0 | **46** 字符 |
| 6.11.1 | **54** 字符 |

而测试构造的名字是 `"PomodoroTodoTest-" + QUuid(36 字符)` = **53 字符** ——
正好落在 6.11.1 的上限之内、6.9.0 的上限之外。这就是同一份代码在两个 Qt 版本上结论相反的全部原因。

**产品代码不受影响**：`src/main.cpp` 用的服务名是 `com.zerionlito.PomodoroTodo`，**27 字符**，
在两个版本上都安全。所以这是纯粹的测试脆弱性，不是用户会遇到的缺陷——但它让
「测试套件全绿」这件事取决于你恰好用了哪个 Qt，等于把回归防线建在流沙上。

修完之后，测试套件在 Qt 6.7 到 6.11 之间任意版本都应当能跑绿。

## Current state

### 相关文件

- `tests/PlatformControlTests.cpp` — 菜单栏与单实例守卫的测试。**本计划只改这一个文件。**
- `src/services/SingleInstanceGuard.cpp` — 被测代码。**本计划不改它**（见 Out of scope）。

### 缺陷代码 1：名字 53 字符（`tests/PlatformControlTests.cpp:223-236`）

```cpp
void PlatformControlTests::repeatedLaunchRequestsExistingWindow()
{
    const QString lockPath = m_tempDir->filePath(QStringLiteral("instance.lock"));
    const QString serverName = QStringLiteral("PomodoroTodoTest-%1")
                                   .arg(QUuid::createUuid().toString(QUuid::WithoutBraces));

    SingleInstanceGuard primary(lockPath, serverName);
    QCOMPARE(primary.start(), SingleInstanceGuard::PrimaryInstance);
    QSignalSpy activationSpy(&primary, &SingleInstanceGuard::activationRequested);

    SingleInstanceGuard secondary(lockPath, serverName);
    QCOMPARE(secondary.start(), SingleInstanceGuard::SecondaryInstanceNotified);
    QTRY_COMPARE_WITH_TIMEOUT(activationSpy.count(), 1, 1000);
}
```

`QUuid::toString(QUuid::WithoutBraces)` 返回 36 字符（含 4 个连字符），
加上 17 字符前缀 `PomodoroTodoTest-` 共 **53** 字符。

### 缺陷代码 2：名字 56 字符（`tests/PlatformControlTests.cpp:238-253`）

```cpp
void PlatformControlTests::unavailableInstanceLockFailsClosed()
{
    // 把“父目录”造成普通文件，QLockFile 必然无法创建锁文件。
    // 这与锁被另一个进程占用不同：应用无法证明单实例，必须关闭失败。
    const QString blockedParent = m_tempDir->filePath(QStringLiteral("not-a-directory"));
    QFile blocker(blockedParent);
    QVERIFY(blocker.open(QIODevice::WriteOnly));
    QVERIFY(blocker.write("blocked") > 0);
    blocker.close();

    SingleInstanceGuard guard(
        blockedParent + QStringLiteral("/instance.lock"),
        QStringLiteral("PomodoroTodoBlocked-%1")
            .arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));
    QCOMPARE(guard.start(), SingleInstanceGuard::LockUnavailable);
}
```

这个名字是 **56** 字符，**在两个 Qt 版本上都超限**。
该用例目前仍然通过，因为 `start()` 在锁获取失败时就返回 `LockUnavailable` 了，
根本走不到 `listen()`。也就是说这里的长名字是"恰好没被用到"的死重，
一旦将来这个用例扩展到检查召回通道，它会立刻变成第二个版本敏感的坑。**顺手一起改掉。**

### 名字为什么必须保持唯一

被测代码在取得排他锁后会先删除同名端点（`src/services/SingleInstanceGuard.cpp:48-50`）：

```cpp
    // 已取得排他锁，才能删除上次崩溃遗留的套接字端点；从进程绝不能碰它，
    // 否则会切断仍存活主进程的召回通道。
    QLocalServer::removeServer(m_serverName);
```

如果两个用例（或并行跑的两个测试进程）用同一个固定名字，前一个的端点会被后一个删掉，
造成随机失败。**所以不能简单改成一个写死的短字符串**，必须保留每次运行的唯一性。

### 目标形态

用 8 位十六进制随机后缀代替 36 字符 UUID：

- `QUuid::createUuid().toString(QUuid::Id128)` 返回 32 个十六进制字符（无连字符、无花括号）。
- 取前 8 位，冲突概率约 1/43 亿，对测试完全够用。
- 前缀缩到 `pt-`，总长 **11 字符**，距离 6.9.0 的 46 上限有极大余量，未来 Qt 再收紧也不会碰到。

### 仓库约定（摘自 `AGENTS.md`）

- 注释必须用中文，解释「为什么这样做」和「边界条件是什么」。
  特别要求注释「测试中为了稳定性或隔离环境而做的特殊处理」——本计划的改动正属于此类，必须写清原因。
- 不要给简单赋值加噪音注释。
- Git 提交说明必须用中文。

## Commands you will need

本计划**必须在两个 Qt 版本上都验证**，这是它存在的全部意义。

| 用途 | 命令 | 成功标志 |
|---|---|---|
| 配置（Qt 6.9.0） | `cmake -B /tmp/pt-005-69 -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0，打印 `使用的 Qt: 6.9.0` |
| 配置（Homebrew Qt） | `cmake -B /tmp/pt-005-brew -S . -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0，打印 `使用的 Qt: 6.11.x` |
| 构建单套件 | `cmake --build <构建目录> --target PlatformControlTests -j8` | 退出码 0 |
| 跑单套件 | `QT_QPA_PLATFORM=offscreen <构建目录>/PlatformControlTests` | `Totals: N passed, 0 failed` |
| 全量测试 | `cd <构建目录> && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | `100% tests passed ... out of 12` |

若 `/Users/zerionlito/Qt/6.9.0/macos` 不存在，用 `ls ~/Qt` 找实际版本目录；
若本机只有一个 Qt 版本，**如实报告**并只验证那一个（见 STOP conditions）。

## Scope

**In scope（只允许修改这一个文件）**：

- `tests/PlatformControlTests.cpp`

**Out of scope（不要动）**：

- `src/services/SingleInstanceGuard.cpp` / `.h` —— 产品用的服务名 27 字符，两个版本都安全，
  **没有缺陷可修**。给它加名字长度校验属于防御性改动，本计划不做（理由见 Maintenance notes）。
- `src/main.cpp` 里的服务名 `com.zerionlito.PomodoroTodo` —— 不要改，改了会让已安装版本
  与新版本互相认不出对方，重复启动时不再召回窗口而是直接起第二个实例。
- `tests/PlatformControlTests.cpp` 里除这两个用例之外的任何内容 —— 该文件还有 15 个
  菜单栏/通知相关用例，与本计划无关。
- 任何其他测试文件。

## Git workflow

- 分支：`advisor/005-shorten-test-socket-names`
- 一次提交即可，说明用中文。参考现有风格：`导出日期校验只认 yyyy-MM-dd`
- 建议：`缩短测试用本地套接字名,避开 Qt 版本相关的长度上限`
- **不要 push，不要开 PR**。

## Steps

### Step 1: 确认失败基线（先复现，再修）

```bash
cmake -B /tmp/pt-005-69 -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-005-69 --target PlatformControlTests -j8
QT_QPA_PLATFORM=offscreen /tmp/pt-005-69/PlatformControlTests
```

**Verify**：必须看到 `repeatedLaunchRequestsExistingWindow` **失败**，且日志里有
`QLocalServer::listen: Name error`。

如果它**通过**了，说明本机的临时目录路径比计划编写时短，触发不了这个问题 ——
按 STOP condition 处理（不要"反正是绿的"就跳过，那样修完也无法证明有效）。

### Step 2: 加一个共用的短名生成辅助

在 `tests/PlatformControlTests.cpp` 的匿名命名空间里（文件顶部 `namespace {` 内，
若没有匿名命名空间则加在 `class PlatformControlTests` 之前）加入：

```cpp
// macOS 上 QLocalServer 的名字长度有上限，且上限随 Qt 版本变化：实测 Qt 6.9.0 是 46 字符、
// Qt 6.11.1 是 54 字符。原来用 "前缀 + 36 字符 UUID" 拼出 53 字符的名字，
// 结果在 6.11 上能过、在 6.9 上必然 "Name error"，同一份代码两个版本结论相反。
// 这里改用 8 位十六进制后缀，总长 11 字符，留足余量；同时保留每次运行的唯一性——
// 名字不能写死，因为被测代码取得锁后会 removeServer(同名端点)，
// 两个用例共用一个名字会互相摘掉对方的端点。
QString uniqueShortServerName()
{
    return QStringLiteral("pt-%1").arg(
        QUuid::createUuid().toString(QUuid::Id128).left(8));
}
```

确认文件顶部已有 `#include <QUuid>`；没有就加上。

### Step 3: 两个用例改用短名

**3a.** `repeatedLaunchRequestsExistingWindow`（:225-227）：

```cpp
    const QString lockPath = m_tempDir->filePath(QStringLiteral("instance.lock"));
    const QString serverName = uniqueShortServerName();
```

**3b.** `unavailableInstanceLockFailsClosed`（:249-251）：

```cpp
    SingleInstanceGuard guard(
        blockedParent + QStringLiteral("/instance.lock"),
        uniqueShortServerName());
```

不要改这两个用例的任何断言 —— 本计划只换名字来源，不改被验证的行为。

**Verify（Qt 6.9.0）**：

```bash
cmake --build /tmp/pt-005-69 --target PlatformControlTests -j8
QT_QPA_PLATFORM=offscreen /tmp/pt-005-69/PlatformControlTests
```
→ `Totals: 17 passed, 0 failed`

### Step 4: 在第二个 Qt 版本上验证没有回退

```bash
cmake -B /tmp/pt-005-brew -S . -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-005-brew --target PlatformControlTests -j8
QT_QPA_PLATFORM=offscreen /tmp/pt-005-brew/PlatformControlTests
```

**Verify**：`Totals: 17 passed, 0 failed`

### Step 5: 连跑确认不是偶然通过

短名带随机后缀，理论上不会冲突，但要确认没有引入端点残留导致的偶发失败：

```bash
for i in 1 2 3 4 5; do
  QT_QPA_PLATFORM=offscreen /tmp/pt-005-69/PlatformControlTests repeatedLaunchRequestsExistingWindow 2>&1 \
    | grep -E "^(PASS|FAIL).*repeatedLaunch"
done
```

**Verify**：5 行全部是 `PASS`。

### Step 6: 两个版本的全量回归

```bash
cmake --build /tmp/pt-005-69 -j8
cd /tmp/pt-005-69 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure
```
→ `100% tests passed, 0 tests failed out of 12`

```bash
cmake --build /tmp/pt-005-brew -j8
cd /tmp/pt-005-brew && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure
```
→ `100% tests passed, 0 tests failed out of 12`

## Test plan

- **不新增测试用例**。本计划修的是既有用例自身的脆弱性，新增用例无助于验证。
- 验证手段是**跨两个 Qt 版本跑同一套测试**（Step 3、4、6）——这正是原问题无法被单版本
  验证发现的原因。
- 反向验证已内建在 Step 1：必须先看到 Qt 6.9.0 上的失败，才能证明 Step 3 的修改真的有效。
- 稳定性验证在 Step 5：连跑 5 次确认短名的唯一性没问题。

## Done criteria

全部必须成立：

- [ ] Step 1 已执行并**观察到失败**（证明基线可复现）
- [ ] `grep -n "QUuid::WithoutBraces" tests/PlatformControlTests.cpp` → 无命中
- [ ] `grep -c "uniqueShortServerName()" tests/PlatformControlTests.cpp` → 3（1 处定义 + 2 处调用）
- [ ] `QT_QPA_PLATFORM=offscreen /tmp/pt-005-69/PlatformControlTests` → `Totals: 17 passed, 0 failed`
- [ ] `QT_QPA_PLATFORM=offscreen /tmp/pt-005-brew/PlatformControlTests` → `Totals: 17 passed, 0 failed`
- [ ] Step 5 连跑 5 次全部 PASS
- [ ] 两个构建目录的 `ctest` 都是 `100% tests passed ... out of 12`
- [ ] `git status --porcelain` 中本计划新增的改动**只涉及** `tests/PlatformControlTests.cpp`
- [ ] `plans/README.md` 中 005 的状态行已更新

## STOP conditions

出现以下任一情况，停下来报告，不要自行发挥：

- Step 1 在 Qt 6.9.0 上**没有复现失败** —— 说明本机环境与计划编写时不同，
  修完也无法证明有效。报告实际观察到的结果。
- 本机只安装了一个 Qt 版本 —— 报告，说明只能单版本验证；不要为了凑齐两个版本去安装 Qt。
- 改成短名后 `repeatedLaunchRequestsExistingWindow` 仍然失败，且日志仍是 `Name error` ——
  说明长度不是唯一原因（可能临时目录路径本身过长），需要重新定位。
- Step 5 的 5 次连跑出现任何一次失败 —— 短名可能引入了端点冲突，报告实际失败信息。
- 你发现要让计划落地就必须改 `src/services/SingleInstanceGuard.cpp` ——
  它在 Out of scope 里，说明本计划的前提有误。
- `git status` 显示你改动了 in-scope 之外的文件。

## Maintenance notes

- **测得的硬数据（供以后参考）**：macOS 上 `QLocalServer::listen()` 能接受的最大名字长度
  实测为 Qt 6.9.0 → 46 字符、Qt 6.11.1 → 54 字符。产品名 `com.zerionlito.PomodoroTodo`
  是 27 字符，安全余量充足。**新增任何用到 `QLocalServer` 的测试时，名字请控制在 40 字符以内。**
- **为什么不给 `SingleInstanceGuard` 加名字长度校验**：产品名是编译期常量且只有 27 字符，
  加运行时校验属于为不存在的问题写代码。真要防，正确位置是在测试里（本计划做的），
  或者在 `main.cpp` 里对常量加一个 `static_assert` 级别的约束——但那需要先决定
  "上限取多少"，而上限随 Qt 版本变化，写死一个数字反而会在升级 Qt 时误报。
- **评审重点**：
  1. 短名必须**保留唯一性**（每次调用生成不同后缀），不能图省事写成固定字符串 ——
     被测代码会 `removeServer(同名端点)`，固定名字会让用例之间互相摘端点；
  2. 两个用例的断言一行都不该变，改动应当只有名字来源；
  3. 验证必须跨两个 Qt 版本，单版本绿不构成通过。
- **本计划显式推迟的事项**：
  - 加 CI 后应当在**至少两个 Qt 版本**上跑矩阵构建，否则这类版本敏感问题还会再出现。
    这是加 CI 时要一并考虑的设计点，不在本计划内。
  - `tests/qml/` 下是否也有类似的版本敏感假设，本计划未排查。
