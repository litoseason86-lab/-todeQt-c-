# Plan 039: 删除恒真断言，并把 qmllint 从整类豁免收紧为逐点基线

> **当前状态（2026-09-05）**：已完成并纳入当前分支；提交证据见 [状态索引](README.md)。下文的执行步骤、旧基线及未勾选验收项均为历史记录，不代表待执行；本轮全量验证 70/70 通过。

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按步骤执行并验证。命中 STOP condition 时停止并汇报。
> 完成后更新 `plans/README.md` 中本计划状态。
>
> **Drift check（先跑）**：
> `git diff --stat f8e3120..HEAD -- CMakeLists.txt README.md docs/运行命令.md tests/RobustnessTests.cpp qml`
> 若 QmlLintGate 参数、告警集合或腐坏库测试已变化，重新运行下文基线命令后再决定。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: test integrity / tooling
- **Planned at**: commit `f8e3120`，2026-08-16

## 基线事实

本计划不是“未来可能更严格”的泛化建议。Qt 6.10.3 已实测证明现有文档和门禁都漂移：

- `missing-property`：文档写 4 条，实际 5 条。
- `use-proper-function`：文档写 6 条，实际 7 条。
- 新增的 `WeekPlanView.qml:186` 告警已进入生产 QML，但 CTest 仍全绿。

根因是 CMake 把两整个 warning 类别设为 `disable`。数量说明只是文字，没有任何机器约束。

另有一条完全独立但同属“门禁失真”的硬错误：`RobustnessTests.cpp:78-80` 的断言含 `|| true`，
所以无论连接状态是什么都通过。

## Current state

### CMake 整类关闭（`CMakeLists.txt:694-701`）

```cmake
COMMAND ${POMODORO_TODO_QMLLINT}
    -I "${CMAKE_CURRENT_SOURCE_DIR}/qml"
    --missing-property disable
    --use-proper-function disable
    --max-warnings 0
    ${POMODORO_TODO_QML_SOURCES}
```

### 文档硬编码旧数字（`docs/运行命令.md:165-168`）

```text
只豁免 missing-property（4 条，工具推导限制）
与 use-proper-function（6 条，项目既定的回调注入模式）
```

### 恒真断言（`tests/RobustnessTests.cpp:78-80`）

```cpp
QVERIFY(!DatabaseManager::instance()->isOpen()
        || !DatabaseManager::instance()->database().isOpen()
        || true);
```

这个 `QVERIFY` 没有测试任何东西。第 77 行真实契约只有“腐坏库初始化必须返回 false”；连接清理当前由 close 兜底，
不应伪装成已验证契约。

## 已知 warning 精确清单（Qt 6.10.3）

`missing-property` 共 5 处：

- `qml/components/SettingsDialog.qml:90,92,94`：`ScrollView.contentItem` 的运行时 Flickable 属性。
- `qml/components/Sidebar.qml:98`：自定义 background 的动态属性。
- `qml/views/WeekPlanView.qml:186`：`ListView.itemAtIndex()` 返回项的 delegate `index`。

`use-proper-function` 共 7 处：

- `qml/components/AddTaskDialog.qml:165,191`
- `qml/components/EditTaskDialog.qml:163`
- `qml/components/FocusTimeline.qml:251`
- `qml/components/ManualSessionDialog.qml:141`
- `qml/components/TaskItem.qml:183`
- `qml/components/settings/ShortcutRecorder.qml:78`

这些都是运行时注入的 JS 回调/函数属性。项目已有正确的局部豁免先例：
`qml/views/DashboardView.qml:238-240` 用成对的
`// qmllint disable use-proper-function` / `enable` 包住单个表达式。

## Scope

**In scope**：

- `CMakeLists.txt`
- `README.md`
- `docs/运行命令.md`
- `tests/RobustnessTests.cpp`
- 上述 9 个含已知 warning 的 QML 文件
- `plans/README.md`（只更新状态）

**Out of scope**：

- 不重构回调注入架构，只做精确、带理由的局部 suppression。
- 不修改 `DatabaseManager::initialize()` 的失败后连接状态契约。
- 不清理其他 warning 类别或顺手格式化 QML。
- 不修改仓库内 `build/`。

## QML 离屏测试红线（必须内联遵守）

- **禁止断言 `visible === true`。** 本项目用 `QT_QPA_PLATFORM=offscreen`，`visible` 会沿父级可见性链级联，
  不能稳定表达组件业务状态。改断言业务属性、控件 `enabled`、`Popup.opened`、模型内容或信号参数。
- **所有“今天/日期”都走逻辑日。** 使用测试现有的 `logicalDayService`、`logicalToday()` 或注入固定 ISO 日期；
  不直接用物理日 `new Date()` 推导今天，否则凌晨 `dayStartHour` 前会得到偶发失败。
- **不要等待或监听 `Popup.onClosed` 作为完成判据。** 离屏环境不保证投递该生命周期回调。
  直接调用被测请求/提交函数，并断言业务状态、`opened` 或控件状态；不要靠 `onClosed` SignalSpy 结束测试。

## Implementation

### Step 1: 固化并保存修复前基线

用目标 Qt SDK 显式打开两类 warning，不能依赖默认级别：

```bash
find qml -type f -name '*.qml' -print0 | sort -z | \
  xargs -0 /Users/zerionlito/Qt/6.10.3/macos/bin/qmllint \
    --ignore-settings -I qml \
    --missing-property warning --use-proper-function warning \
    --max-warnings 1000
```

确认仍是 5 / 7，且路径与上表一致。若数量或路径不同，STOP：先更新基线，不能照旧清单盲加豁免。

**Verify**：命令 exit 0，输出可人工归类为精确 5 条 `missing-property` 与 7 条 `use-proper-function`，
没有第三种 warning。

### Step 2: 为每个已知点加局部 suppression

在每个表达式前后用成对的 `qmllint disable/enable`，范围只包住必要行。每处配中文注释说明静态工具为什么无法推导
运行时类型或注入回调；禁止在文件头关闭整类。

三个相邻的 `SettingsDialog` 动态属性可以用一个最小连续区间包住；其余逐表达式处理。
不要借机把 callback property 改成 signal，避免把 S 任务膨胀成跨组件 API 重构。

**Verify**：重跑基线命令并把 `--max-warnings 1000` 改成 `0`
→ exit 0、0 warning；`rg -n "qmllint disable (missing-property|use-proper-function)"` 的新增命中只在清单文件内。

### Step 3: CMake 显式启用类别并零容忍新增长

把 `QmlLintGate` 改为：

- 增加 `--ignore-settings`，避免开发者本机 `.qmllint.ini` 改写门禁。
- `--missing-property warning`
- `--use-proper-function warning`
- 保持 `--max-warnings 0`

更新 `CMakeLists.txt:675-685` 注释：现在的判据是“类别显式开启，已知误报逐点压制，其他位置新增一条就失败”，
而不是“整类豁免”。

**Verify**：`ctest --test-dir ~/pt-audit -R '^QmlLintGate$' --output-on-failure`
→ 1/1 passed；`rg -- "--(missing-property|use-proper-function) disable" CMakeLists.txt` → 0 命中。

### Step 4: 删除恒真断言，不虚构新契约

保留：

```cpp
QVERIFY(!DatabaseManager::instance()->initialize(corruptPath));
```

删除 `|| true` 所在整个第二个 `QVERIFY`。把注释改成中文，明确该用例只验证“初始化拒绝腐坏库”；
失败后的连接释放由 `cleanup()/close()` 负责，本计划不把它升级为接口保证。

不要简单删掉 `|| true` 后保留剩余 OR：那会在现有实现上偶然通过，并把未确认的内部连接状态变成脆弱测试。

**Verify**：`rg -n "\\|\\| true|&& true" tests` → 0 命中；
`~/pt-audit/RobustnessTests initializeReportsFailureOnCorruptDatabaseFile` → 0 failed。

### Step 5: 文档记录事实，不再维护易漂移计数

更新 `README.md` 与 `docs/运行命令.md`：

- 记录 `f8e3120` 修复前官方 Qt 6.10.3 基线确为 5 / 7，旧 4 / 6 已失真。
- 说明当前 CTest 显式开启两类并逐点 suppression，因此门禁输出应为 0。
- 后续新增 warning 必须修复或在具体位置说明原因，不能增加全局允许数量。
- 手工命令增加 `--ignore-settings` 和两个显式 `warning` 参数，确保与门禁同口径。

这一步直接纠正文档，不要把数字仅改为 5 / 7 后继续声称“门禁豁免 5 / 7”；完成后机器门禁看到的是 0。

**Verify**：`rg -n "4 条|6 条|missing-property.*disable|use-proper-function.*disable" README.md docs/运行命令.md`
→ 0 个仍描述当前门禁的旧口径；历史基线只允许明确写成“修复前 5/7”。

### Step 6: 证伪门禁

临时移除任一局部 `qmllint disable`，运行 `QmlLintGate`，必须失败；还原文件并确认通过。
再检查仓库不存在 `--missing-property disable` 或 `--use-proper-function disable`。
不要提交证伪改动。

**Verify**：移除 suppression 时 `QmlLintGate` 非零；还原并 `touch` 文件后 1/1 passed；`git diff` 不含证伪改动。

## Test plan

- 静态门禁：官方 Qt 6.10.3、`--ignore-settings`、两类别显式 warning、零允许新增。
- 鲁棒性测试：只保留可观察的初始化返回值契约，删除恒真语句。
- mutation：移除任意一处局部豁免，证明 CTest 真能抓住新增告警。
- 全量回归：QML 文本格式门禁也运行，防止注释插入破坏现有检查脚本。

## Verification

```bash
/Users/zerionlito/Qt/6.10.3/macos/bin/qt-cmake \
  -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build ~/pt-audit -j8

find qml -type f -name '*.qml' -print0 | sort -z | \
  xargs -0 /Users/zerionlito/Qt/6.10.3/macos/bin/qmllint \
    --ignore-settings -I qml \
    --missing-property warning --use-proper-function warning \
    --max-warnings 0

QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit \
  -R '^(RobustnessTests|QmlLintGate|QmlTextFormatGate)$' --output-on-failure
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8
```

预期：手工 qmllint 0 warning、三条门禁/测试通过、全量通过。

## Done criteria

- 仓库无 `|| true` 虚假断言。
- QmlLintGate 不再全局 disable 两类 warning。
- 12 个已知 warning 点有最小范围、成对、带原因的局部 suppression。
- 任一新位置出现同类 warning 都会使 CTest 非零退出。
- README/运行命令与真实门禁一致，不再把 4/6 写成硬事实。

## STOP conditions

- Qt 6.10.3 重跑结果不是 5 / 7，或告警原因已不是静态推导限制/动态回调。
- 局部 suppression 在目标 qmllint 版本中会泄漏到文件后续区域，无法成对恢复。
- 移除 `|| true` 后有人要求验证 initialize 失败后的严格连接关闭状态；先定义并实现正式契约，不能靠测试猜。

## Maintenance notes

- 升级 Qt 后先显式重跑两类 warning；若工具修复误报，删除对应局部 suppression，不保留死豁免。
- 新 suppression 必须附运行时类型/回调来源理由，reviewer 应拒绝文件级或目录级 disable。
- 文档不再维护“允许多少条”作为门禁事实；真实允许值永远是 0，已知点由代码旁注释解释。

## Git workflow

- 建议分支：`advisor/039-tighten-verification-gates`
- 建议提交：`收紧 QML 静态门禁并删除恒真断言`
- 不 push、不创建 PR，除非维护者明确要求。
