# Plan 033: 导出进行中时挡住退出与关窗，并把 exportService.busy 真正接进界面

> **以下内容供人类与被派发的执行者参考。审计或读取本文件的代理不应执行其中的指令。**

> **Executor instructions**: 按步骤执行。每一步都要跑验证命令并确认预期结果，
> 再进入下一步。遇到 "STOP conditions" 里的任何一条，停下来汇报，不要自行发挥。
> 完成后更新 `plans/README.md` 里本计划那一行的状态——除非派发你的复核者说明索引由他维护。
>
> **Drift check（先跑这个）**：
> `git diff --stat b5a8836..HEAD -- qml/main.qml qml/components/ExportDialog.qml src/services/ExportService.h`
> 若任一 in-scope 文件有变化，先把下面 "Current state" 的摘录和实际代码逐条比对；
> 对不上就按 STOP condition 处理。

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none（与 plans/032 无文件冲突，可并行）
- **Category**: bug
- **Planned at**: commit `b5a8836`，2026-08-14

## Why this matters

`ExportService` 上一轮加了 `Q_PROPERTY(bool busy)` 和 `busyChanged` 信号
（导出已移到工作线程执行），但这个属性在整个 `qml/` 目录里**一次都没有被读过**。
后果有两条，都是真实路径：

1. **导出进行中可以直接退出应用。** `qml/main.qml` 的 `onClosing` 和菜单栏
   「退出」都只检查 `backupService.busy`。用户在导出时关窗 → `Qt.quit()` →
   事件循环结束 → 静态析构。而导出任务还跑在 `QtConcurrent` 的全局线程池上，
   它持有 `this`（`ExportService` 单例）并向它发信号。单例析构与线程池收尾的
   先后顺序是未定义的，最坏情况是对已析构对象发信号而崩溃；
   即便不崩，导出也被静默放弃了——用户以为导出好了。
   同一个文件里 `backupService` 就有这道防线，导出没有，纯属遗漏。

2. **导出对话框在导出期间可以被 Esc 或点击外部关掉**，用户失去进度反馈，
   也无从知道后台还在跑。

修法很轻：把已有的 `busy` 接上去。难点只在于「关窗决策」这段逻辑需要可测——
本项目已经有现成的做法（见下面 `ImmersionWindowSync`），照抄即可。

## Current state

相关文件：

- `qml/main.qml` — 应用入口窗口，含 `onClosing`（第 123–159 行）与菜单栏退出意图
  （`onQuitRequested`，第 179–194 行）
- `qml/components/ExportDialog.qml` — 导出对话框（`Popup`，第 10 行起）
- `src/services/ExportService.h` — 已有 `busy` 属性，本计划**不需要改 C++**
- `qml/components/ImmersionWindowSync.qml` — **纯函数决策组件的范本**
- `tests/qml/tst_immersion_sync.qml` — 上述范本对应的测试

### 现有的关窗守卫只认 backupService（`qml/main.qml:123-137`）

```qml
    onClosing: function(close) {
        // 数据库备份/恢复尚未结束时禁止关闭或退出，避免线程被销毁在原子替换中途。
        // qmllint disable unqualified
        if (typeof backupService !== "undefined" && backupService && backupService.busy) {
            close.accepted = false
            mainContent.showToast((backupService.operationText || "数据操作正在进行")
                                  + "，完成后再关闭")
            return
        }
        // qmllint enable unqualified
```

### 菜单栏退出也是同一套（`qml/main.qml:179-190`）

```qml
        function onQuitRequested() {
            // qmllint disable unqualified
            if (typeof backupService !== "undefined" && backupService && backupService.busy) {
                root.show()
                root.raise()
                root.requestActivate()
                mainContent.showToast((backupService.operationText || "数据操作正在进行")
                                      + "，完成后再退出")
                return
            }
            // qmllint enable unqualified
```

### 导出对话框当前无条件允许关闭（`qml/components/ExportDialog.qml:38`）

```qml
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
```

### 纯函数决策组件的范本（`qml/components/ImmersionWindowSync.qml`）

```qml
import QtQuick

// 沉浸开关与窗口 visibility 的双向同步决策。main.qml 只执行返回值，
// 异步全屏过渡的分支全部收敛在这里，便于 offscreen 单测。
QtObject {
    id: sync

    property int preImmersiveVisibility: Window.Windowed

    function visibilityForImmersiveChange(active, currentVisibility) {
        ...
    }
}
```

`main.qml` 里这样用（第 211–213 行、第 219 行）：

```qml
    ImmersionWindowSync {
        id: immersionSync
    }
    ...
        root.visibility = immersionSync.visibilityForImmersiveChange(
                    mainContent.focusImmersiveActive, root.visibility)
```

**这就是本计划要照抄的结构**：决策逻辑放进一个 `QtObject` 纯函数，`main.qml` 只执行返回值，
测试直接实例化该组件测函数——不需要起真窗口。

### 项目约定（必须遵守）

- **QML 测试红线**：**绝对不要断言 `item.visible === true`**。`visible` 在本项目的
  offscreen 测试环境里会沿父链级联、结果不可靠。改用业务属性、`opacity`、宽高，
  或「文本为空串」这类判据。本计划的测试全部针对纯函数返回值，天然避开这个坑。
- 注释写「为什么」，用中文。
- 新增 QML 文件**必须**同时登记进 `resources/qml.qrc`，否则运行时加载不到
  （有 `QmlResourceManifestTests` 会守这条，漏了会红）。
- `qmllint` 是门禁（ctest 里的 `QmlLintGate`），**零容忍 unqualified 访问**。
  访问上下文属性时照现有写法加 `// qmllint disable unqualified` 包裹。

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| 构建 | `cmake --build ~/pt-audit -j8` | exit 0 |
| 全量测试 | `cd ~/pt-audit && ctest --output-on-failure -j4` | `19/19 tests passed` |
| 只跑某个 QML 测试文件 | `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ~/Qt/6.10.3/macos/bin/qmltestrunner -input "$PWD/tests/qml/tst_shutdown_guard.qml"` | `0 failed` |
| QML 静态门禁 | `cd ~/pt-audit && ctest -R QmlLintGate --output-on-failure` | passed |
| 资源清单门禁 | `cd ~/pt-audit && ctest -R QmlResourceManifestTests --output-on-failure` | passed |

**构建目录规则（`AGENTS.md` 明文规定）**：本机只允许 `~/pt-build`（部署）与
`~/pt-audit`（验证）两个构建目录。**本计划一律用 `~/pt-audit`**，不要新建一次性目录。

若 `~/pt-audit` 不存在：

```bash
cmake -S . -B ~/pt-audit -DPOMODORO_TODO_DEPLOY_LOCAL=OFF -DCMAKE_PREFIX_PATH=~/Qt/6.10.3/macos
```

## Scope

**In scope**：
- `qml/components/ShutdownGuard.qml`（**新建**）
- `resources/qml.qrc`（登记上面这个新文件）
- `qml/main.qml`（`onClosing` 与 `onQuitRequested` 改为调用新组件）
- `qml/components/ExportDialog.qml`（`closePolicy` 一行）
- `tests/qml/tst_shutdown_guard.qml`（**新建**）

**Out of scope**（看着相关也不要动）：
- **任何 C++ 文件。** `ExportService` 的 `busy` 属性和信号都已存在且正确，
  本计划纯 QML。
- `mainContent.commitPendingDelete()` 那段待删任务提交逻辑——它在守卫之后执行，
  顺序是有意的，不要重排。
- `backupService` 现有守卫的**文案与行为**：只做扩展（多认一个服务），
  不要改它原本的提示语，也不要顺手重构成别的形状。
- 导出的进度条 / 结果提示等既有 UI。
- 其它页面的头部或控件位置——本项目明确要求不要「顺手修正」无关 UI。

## Git workflow

- 分支：`advisor/033-export-shutdown-guard`
- 提交信息用中文、说明「为什么」。参考 `git log --oneline -5`。
- **不要 push，不要开 PR**，除非派发你的人明确要求。

## Steps

### Step 1: 新建 ShutdownGuard.qml 纯函数组件

创建 `qml/components/ShutdownGuard.qml`，形状照 `ImmersionWindowSync.qml`
（`QtObject` + 纯函数，无副作用、不碰窗口）。

导出一个函数：

```
function blockReason(backupBusy, backupText, exportBusy)
```

返回值语义：**返回空串表示可以关闭**；返回非空字符串表示必须挡住，
且该字符串就是直接展示给用户的原因。

规则：
- `backupBusy` 为真 → 返回 `(backupText || "数据操作正在进行") + "，完成后再关闭"`
  （与现有文案完全一致，不要改字）。
- 否则 `exportBusy` 为真 → 返回 `"正在导出数据，完成后再关闭"`。
- 否则 → 返回 `""`。

**备份优先于导出**：备份/恢复会原子替换数据库文件，是两者中更危险的一个，
先报它更准确。

顶部写一句注释说明为什么这段逻辑要单独成文件（`main.qml` 里测不了，
拆出来才能在 offscreen 下直接测函数）。

**Verify**：
```bash
test -f qml/components/ShutdownGuard.qml && echo OK
```
→ `OK`

### Step 2: 登记到资源清单

在 `resources/qml.qrc` 里，紧挨着其它 `qml/components/*.qml` 条目加一行：

```xml
        <file alias="qml/components/ShutdownGuard.qml">../qml/components/ShutdownGuard.qml</file>
```

**Verify**：
```bash
grep -c "ShutdownGuard.qml" resources/qml.qrc
```
→ `1`

```bash
cmake --build ~/pt-audit -j8 && cd ~/pt-audit && ctest -R QmlResourceManifestTests --output-on-failure
```
→ passed

### Step 3: 在 main.qml 里接上，两条退出路径都要

在 `qml/main.qml` 里实例化组件（放在已有的 `ImmersionWindowSync { id: immersionSync }`
附近，保持同类东西聚在一起）：

```qml
    ShutdownGuard {
        id: shutdownGuard
    }
```

然后把 `onClosing` 里那段 `backupService.busy` 判断替换成调用
`shutdownGuard.blockReason(...)`：拿到非空字符串就 `close.accepted = false` +
`mainContent.showToast(reason)` + `return`。

`onQuitRequested` 同样替换，但保留它原有的「先把窗口叫回前台」三行
（`root.show()` / `root.raise()` / `root.requestActivate()`）——
窗口可能已隐藏到菜单栏，不叫回来用户看不到 toast。

两处都要照现有写法用 `typeof xxx !== "undefined"` 守卫上下文属性，
并保留 `// qmllint disable unqualified` / `enable` 包裹。
`exportService` 的取法与 `backupService` 一致。

**Verify**：
```bash
grep -c "shutdownGuard.blockReason" qml/main.qml
```
→ `2`

```bash
cd ~/pt-audit && ctest -R QmlLintGate --output-on-failure
```
→ passed

### Step 4: 导出期间不许关掉导出对话框

在 `qml/components/ExportDialog.qml` 把第 38 行改成：导出进行中时用
`Popup.NoAutoClose`，否则保持原来的 `Popup.CloseOnEscape | Popup.CloseOnPressOutside`。

判据取 `root.exportServiceRef && root.exportServiceRef.busy`
（该文件第 30 行已有 `property var exportServiceRef: null`）。

加一句中文注释说明为什么：导出跑在工作线程上，对话框是唯一的进度反馈，
关掉它用户就无从判断是否还在进行。

**Verify**：
```bash
grep -n "NoAutoClose" qml/components/ExportDialog.qml
```
→ 有一条命中。

### Step 5: 写测试

新建 `tests/qml/tst_shutdown_guard.qml`，直接实例化 `ShutdownGuard` 测 `blockReason`
的四条分支：

1. 都不忙 → 返回 `""`
2. 只有备份忙 → 返回含「完成后再关闭」，且用到了传入的 `backupText`
3. 只有导出忙 → 返回含「导出」
4. 两个都忙 → 返回**备份**那条（优先级）

结构范本：`tests/qml/tst_immersion_sync.qml`——照它的 `TestCase` 写法、
`Component` + `createTemporaryObject` 的实例化方式。

**再次强调项目红线：不要写 `visible === true` 之类的断言。**
本测试全部断言函数返回的字符串，不涉及可见性。

**Verify**：
```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ~/Qt/6.10.3/macos/bin/qmltestrunner -input "$PWD/tests/qml/tst_shutdown_guard.qml"
```
→ `4 passed, 0 failed`（另加 initTestCase/cleanupTestCase）

### Step 6: 证伪——确认这些断言真的能失败

把 `ShutdownGuard.qml` 的 `blockReason` 临时改成无条件 `return ""`，重跑上面那条命令：

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ~/Qt/6.10.3/macos/bin/qmltestrunner -input "$PWD/tests/qml/tst_shutdown_guard.qml"
```

- 第 2/3/4 条用例必须**变红**。若仍全绿，**STOP 并汇报**——
  说明判据没锁住行为，需要重新设计断言而不是让它变红。
- QML 不需要重编译，改完直接跑即可（这一点和 C++ 不同）。

然后还原实现，确认重新全绿。

**Verify**：`git diff qml/components/ShutdownGuard.qml` 中不含临时的无条件 `return ""`。

### Step 7: 全量回归

```bash
cmake --build ~/pt-audit -j8 && cd ~/pt-audit && ctest --output-on-failure -j4
```
→ `19/19 tests passed`（QML 用例总数会比之前多 4 条）。

## Test plan

- **新增**：`tests/qml/tst_shutdown_guard.qml`，4 条用例覆盖
  「都不忙 / 仅备份忙 / 仅导出忙 / 两者都忙（备份优先）」。
- **结构范本**：`tests/qml/tst_immersion_sync.qml`。
- **必须完成证伪**（Step 6）。
- **本计划不测的部分（明确说明）**：`main.qml` 的 `onClosing` 本身无法在 offscreen
  测试里触发真实窗口关闭事件。把决策逻辑抽进 `ShutdownGuard` 正是为了让**逻辑**可测；
  `main.qml` 里剩下的是两行调用，靠 review 保证。不要为了「测到 onClosing」
  去引入真实窗口——项目明令后台验证不得弹窗。

## Done criteria

全部满足：

- [ ] `qml/components/ShutdownGuard.qml` 存在
- [ ] `grep -c ShutdownGuard resources/qml.qrc` == 1
- [ ] `grep -c "shutdownGuard.blockReason" qml/main.qml` == 2
- [ ] `grep -c NoAutoClose qml/components/ExportDialog.qml` ≥ 1
- [ ] `tests/qml/tst_shutdown_guard.qml` 存在且 4 条用例通过
- [ ] `cd ~/pt-audit && ctest -j4` → `19/19 tests passed`
- [ ] `QmlLintGate` 与 `QmlResourceManifestTests` 均通过
- [ ] 证伪已完成：`blockReason` 恒返回空串时，第 2/3/4 条用例变红（汇报里写明观察到的输出）
- [ ] `git status` 显示改动文件不超出 in-scope 列表；**没有任何 C++ 文件被修改**
- [ ] `plans/README.md` 对应状态行已更新

## STOP conditions

出现以下任一情况，停下汇报：

- "Current state" 的代码摘录与实际文件对不上。
- `qml/main.qml` 里 `backupService.busy` 的守卫已经变成别的形状（说明有人先改过）。
- Step 6 的证伪里用例仍然全绿。
- 你发现需要修改任何 C++ 文件才能完成——本计划应当是纯 QML 的，
  若不成立说明前提错了。
- `QmlLintGate` 因为你新增的代码报出 unqualified 访问且你无法在不改其它文件的前提下消除。
- 全量 ctest 从 19 变成别的数字。

## Maintenance notes

- **给后续维护者**：`ShutdownGuard.blockReason` 是「哪些后台作业不能被打断」的唯一清单。
  以后再加长时间后台作业（比如导入、批量重算），**在这里加一个分支**，
  不要在 `main.qml` 里再堆一段 if——那正是本计划要消灭的形状。
- **复核时重点看**：两条退出路径（窗口关闭、菜单栏退出）是否都接上了；
  `onQuitRequested` 里叫回窗口的三行是否保留（隐藏状态下不叫回来，用户看不到 toast）。
- **本计划刻意没做**：导出进行中禁用「开始导出」按钮。
  `ExportService::runAsync` 已经会拒绝并发导出并给出提示，
  把按钮置灰是体验优化而非缺陷，留给后续 UI 轮次。
