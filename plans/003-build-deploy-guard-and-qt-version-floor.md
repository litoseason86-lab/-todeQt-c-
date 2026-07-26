# Plan 003: 给部署删除加护栏、锁定 Qt 版本下界、校正构建文档

> **Executor instructions**: 按步骤执行本计划。每一步都要运行验证命令并确认预期结果，
> 再进入下一步。若触发 "STOP conditions" 里的任何一条，立即停下来报告，**不要自行发挥**。
> 完成后更新 `plans/README.md` 里本计划的状态行（除非派发你的评审者说明由他维护索引）。
>
> **Drift check（先跑这个）**：
> `git diff --stat 43ba2ee..HEAD -- CMakeLists.txt README.md docs/运行命令.md`
> 若任一 in-scope 文件有改动，先把下面 "Current state" 的摘录与实际内容逐行比对；
> 不一致就按 STOP condition 处理。
> （注意：`CMakeLists.txt` 在 `43ba2ee` 时有未提交改动——那是长期目标功能新增的构建目标，
> 与本计划改动的区域不重叠。只要下面第 1、2 段摘录能对上就可以继续。）

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `43ba2ee`, 2026-07-26

## Why this matters

三件互相关联的小事，合起来是「构建地基不稳」：

1. **默认构建目标里有一句 `/bin/rm -rf "${可被命令行覆盖的路径}"`**。
   该路径是 CMake cache 变量，`-DPOMODORO_TODO_LOCAL_APP_PATH=~/Applications` 这样一个笔误，
   就会在下次构建时递归删掉整个目录，没有确认、没有回滚。删除前不校验目标是不是一个 `.app` 包。

2. **`find_package(Qt6)` 没有版本下界**，而代码已经在用 Qt 6.7 才引入的
   `QDateTime::TransitionResolution`。忘记传 `CMAKE_PREFIX_PATH` 时，CMake 会静默配到系统里
   任何一个 Qt 上——事实上**当前 `/Applications/番茄Todo.app` 里的二进制链接的是 Homebrew 的
   Qt 6.11.1，而不是文档里写的 6.9.0**。用低于 6.7 的 Qt 配置则会成功配置、编译期才炸，
   对新贡献者是纯浪费时间的失败模式。

3. **文档把「跑一次测试」和「替换用户已安装的应用」混成了同一条命令**。
   README 的构建快速上手用的是仓库内 `build/` 目录且不带 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`，
   而 `AGENTS.md` 明确要求「构建目录放在仓库外的临时目录」。照 README 操作的人只是想跑个测试，
   却会静默覆盖掉 `/Applications/番茄Todo.app`——如果这次构建带着未完成的改动，
   用户下次打开的就是半成品。同时 `docs/运行命令.md` 声称的测试规模（8 个目标 / 180 用例 /
   29 个 QML 测试）与现实（12 / 236 / 30）对不上，而这个数字是判断「我是不是漏跑了套件」的唯一参考。

**本计划不改变「构建即部署」这个既定工作流** —— `AGENTS.md:42` 明确要求
「应用构建必须以 CMake 的 `deploy-local-app` 目标结束」，那是有意的决定。
本计划只做三件事：给删除加护栏、给 Qt 版本加下界、让文档把「验证构建」和「部署构建」分开写清楚。

## Current state

### 缺陷 1：部署目标里的裸 `rm -rf`（`CMakeLists.txt:150-173`）

```cmake
# 日常开发目录保持自动同步；审计/CI/临时构建传 -DPOMODORO_TODO_DEPLOY_LOCAL=OFF，
# 避免非正式构建悄悄覆盖固定启动入口。
option(POMODORO_TODO_DEPLOY_LOCAL "构建后自动把应用同步到本机固定启动入口" ON)

if(APPLE AND POMODORO_TODO_DEPLOY_LOCAL)
    set(POMODORO_TODO_LOCAL_APP_PATH "/Applications/番茄Todo.app" CACHE PATH
        "本机固定启动入口，构建后会用最新包覆盖这里"
    )
    set(POMODORO_TODO_LSREGISTER
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    )

    add_custom_target(deploy-local-app ALL
        COMMAND ${CMAKE_COMMAND} -E echo "Deploying PomodoroTodo to ${POMODORO_TODO_LOCAL_APP_PATH}"
        COMMAND /bin/rm -rf "${POMODORO_TODO_LOCAL_APP_PATH}"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "$<TARGET_BUNDLE_DIR:PomodoroTodo>" "${POMODORO_TODO_LOCAL_APP_PATH}"
        # LaunchOS 依赖系统应用索引；复制后主动刷新固定入口。build 目录里的临时包可能从未注册，
        # lsregister -u 在这种情况下会返回错误码，因此撤销临时包索引只能作为尽力而为步骤。
        COMMAND /bin/sh -c "'${POMODORO_TODO_LSREGISTER}' -u '$<TARGET_BUNDLE_DIR:PomodoroTodo>' >/dev/null 2>&1 || true"
        COMMAND "${POMODORO_TODO_LSREGISTER}" -f "${POMODORO_TODO_LOCAL_APP_PATH}"
        DEPENDS PomodoroTodo
        VERBATIM
    )
endif()
```

要点：`add_custom_target(... ALL ...)` 意味着**每次 `cmake --build` 都会跑**；
`POMODORO_TODO_LOCAL_APP_PATH` 是 `CACHE PATH`，命令行可任意覆盖；删除前无任何校验。

### 缺陷 2：`find_package` 无版本下界（`CMakeLists.txt:14`）

```cmake
find_package(Qt6 REQUIRED COMPONENTS Concurrent Core Gui Network Quick QuickControls2 QuickLayouts QuickTest Sql Test)
```

代码已用到的 Qt 6.7 API（`src/services/LogicalDay.h:25-33`）：

```cpp
inline qint64 msUntilNextBoundary(const QDateTime& now, int dayStartHour)
{
    const QDate boundaryDate = now.time() < QTime(dayStartHour, 0)
        ? now.date() : now.date().addDays(1);
    // 使用调用方时区构造本地墙钟边界；DST 跳变交给 QDateTime 的时区转换规则处理。
    const QDateTime boundary(boundaryDate, QTime(dayStartHour, 0), now.timeZone(),
                             QDateTime::TransitionResolution::RelativeToBefore);
    return now.msecsTo(boundary);
}
```

`QDateTime::TransitionResolution` 是 Qt 6.7 引入的。

实测证据（执行者可自行复核）：

```
$ otool -L /Applications/番茄Todo.app/Contents/MacOS/PomodoroTodo | grep -i qtcore
	/opt/homebrew/opt/qtbase/lib/QtCore.framework/Versions/A/QtCore (compatibility version 6.0.0, current version 6.11.1)
```

而 `README.md:14` 写的是「当前验证使用的是 Qt 6.9.0」。

### 缺陷 3：文档（`README.md:16-22`）

```markdown
需要先安装 Qt 6 SDK，并把 Qt 的 CMake 前缀传给 CMake。当前验证使用的是 Qt 6.9.0：

```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos
cmake --build build
ctest --test-dir build --output-on-failure
```
```

这条命令：用仓库内 `build/` 目录（`AGENTS.md:44` 禁止），且不带 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`
（会覆盖 `/Applications/番茄Todo.app`）。

`docs/运行命令.md:39`：

```
# 全套（8 个目标：C++ 180 用例 + QML 29 个测试文件）
```

实测：`grep -c "add_test" CMakeLists.txt` → **12**；`tests/qml/tst_*.qml` → **30** 个文件。
另外 `docs/运行命令.md:42-49` 的「只跑单个测试目标」清单只列了 4 个，缺
`GoalServiceTests`、`BackupServiceTests`、`TimingRobustnessTests`、`PlatformControlTests`
及三个 Assets 套件。

### 必须尊重的既定决定（摘自 `AGENTS.md:40-47`）

执行者没读过这份文档，以下直接内联，**本计划不得违背**：

```
## 构建与部署规则

- 用户说"构建""重新构建"或要求生成最新应用时，默认含部署步骤，不能只生成临时目录中的 `.app`。
- 应用构建必须以 CMake 的 `deploy-local-app` 目标结束，将当前分支的最新应用部署到
  `/Applications/番茄Todo.app`。该目标负责删除旧包、复制新包并通过 `lsregister` 刷新系统索引。
- 构建目录放在仓库外的临时目录，禁止修改仓库内 `build/` 生成物。
- 部署完成后必须校验构建包与 `/Applications/番茄Todo.app` 主二进制一致，并报告部署结果。
```

**所以：不要把 `POMODORO_TODO_DEPLOY_LOCAL` 的默认值改成 `OFF`。** 那会推翻上面第一、二条。
本计划只加护栏，不改默认行为。

### 仓库约定

- 注释与文档必须用中文（`AGENTS.md`「回复语言」「代码注释规则」）。
- Git 提交说明必须用中文。

## Commands you will need

| 用途 | 命令 | 成功标志 |
|---|---|---|
| 配置（验证用，不部署） | `cmake -B /tmp/pt-003 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | 退出码 0 |
| 全量构建 | `cmake --build /tmp/pt-003 -j8` | 退出码 0 |
| 全量测试 | `cd /tmp/pt-003 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | `100% tests passed ... out of 12` |
| 数测试目标 | `grep -c "add_test" CMakeLists.txt` | 一个整数 |
| 数 QML 测试文件 | `ls tests/qml/tst_*.qml \| wc -l` | 一个整数 |
| 数 C++ 用例 | 见 Step 4 | 一个整数 |

`<Qt前缀>`：先跑 `ls ~/Qt` 找到已安装版本（例如 `/Users/zerionlito/Qt/6.9.0/macos`）。
若目录不存在，用 `brew --prefix qt` 的输出。两者都没有则按 STOP condition 处理。

## Scope

**In scope（只允许修改这三个文件）**：

- `CMakeLists.txt`（仅 :12-16 的 `find_package` 行与 :150-173 的部署段）
- `README.md`（仅「构建」一节）
- `docs/运行命令.md`

**Out of scope（不要动）**：

- `AGENTS.md` —— 它记录的是已决定的工作流，本计划要**服从**它，不是修改它。
- `CMakeLists.txt` 里除上述两段之外的任何内容 —— 尤其是各测试目标的源文件清单
  （其中 `GoalServiceTests` 等目标属于在途功能，与本计划无关）。
- `POMODORO_TODO_DEPLOY_LOCAL` 的**默认值** —— 保持 `ON`（见上方 AGENTS.md 引文）。
- 任何 `src/` 或 `qml/` 下的源码 —— 本计划不改代码行为。
- 把 Qt 升级到 6.11 或修改 CI —— 不在本计划内。

## Git workflow

- 分支：`advisor/003-build-guard-and-qt-floor`
- 每个 Step 一次提交，说明用中文。参考现有风格：`忽略 build-* 变体构建目录`、`新增运行命令文档:构建/测试/打包/启动速查`
- 建议：
  - Step 1：`部署目标删除前校验路径必须是 .app 包`
  - Step 2：`锁定 Qt 最低版本 6.7 并在配置时打印实际使用的 Qt`
  - Step 3-4：`校正构建与测试文档:区分验证构建与部署构建`
- **不要 push，不要开 PR**。

## Steps

### Step 1: 给部署删除加护栏

在 `CMakeLists.txt` 的 `if(APPLE AND POMODORO_TODO_DEPLOY_LOCAL)` 块内，
`set(POMODORO_TODO_LOCAL_APP_PATH ...)` 之后、`set(POMODORO_TODO_LSREGISTER ...)` 之前插入校验：

```cmake
    # 这个路径是 cache 变量，命令行可以覆盖，而下面的部署步骤会对它执行递归删除。
    # 写错一层目录就会不可逆地删掉无关内容，所以在配置阶段就挡住不像应用包的路径。
    if(NOT POMODORO_TODO_LOCAL_APP_PATH MATCHES "\\.app$")
        message(FATAL_ERROR
            "POMODORO_TODO_LOCAL_APP_PATH 必须指向一个 .app 应用包，当前值："
            "${POMODORO_TODO_LOCAL_APP_PATH}。若只想构建而不部署，请传 -DPOMODORO_TODO_DEPLOY_LOCAL=OFF。")
    endif()
```

再把删除命令从 `/bin/rm` 换成 CMake 自带的跨平台实现（行为一致，但不依赖 shell 解析）：

```cmake
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${POMODORO_TODO_LOCAL_APP_PATH}"
```

**Verify**：

```bash
# 1) 正常配置仍然成功
cmake -B /tmp/pt-003 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
```
→ 退出码 0

```bash
# 2) 护栏确实拦得住：给一个不是 .app 的路径，且开启部署
cmake -B /tmp/pt-003-guard -S . -DCMAKE_PREFIX_PATH=<Qt前缀> \
      -DPOMODORO_TODO_LOCAL_APP_PATH=/tmp/not-an-app-bundle
```
→ **必须失败**，且输出包含 `必须指向一个 .app 应用包`。若配置成功了，护栏没生效，按 STOP condition 处理。

```bash
# 3) 合法路径仍然放行
cmake -B /tmp/pt-003-ok -S . -DCMAKE_PREFIX_PATH=<Qt前缀> \
      -DPOMODORO_TODO_LOCAL_APP_PATH=/tmp/番茄Todo.app
```
→ 退出码 0

```bash
# 4) 清理临时配置目录（这几个目录只用于验证护栏，不要留下）
rm -rf /tmp/pt-003-guard /tmp/pt-003-ok
```

```bash
# 5) 确认裸 rm 已消失
grep -n "/bin/rm" CMakeLists.txt
```
→ 无命中

### Step 2: 锁定 Qt 最低版本并打印实际使用的 Qt

**2a.** 把 `CMakeLists.txt:14` 改成带版本下界：

```cmake
# 6.7 是 QDateTime::TransitionResolution 的引入版本（见 src/services/LogicalDay.h 的逻辑日边界计算）。
# 不写下界的话，用更低版本的 Qt 也能配置成功，报错要推迟到编译期才出现。
find_package(Qt6 6.7 REQUIRED COMPONENTS Concurrent Core Gui Network Quick QuickControls2 QuickLayouts QuickTest Sql Test)
```

**2b.** 紧随其后加一行状态输出，让每次配置都把实际使用的 Qt 打出来
（不传 `CMAKE_PREFIX_PATH` 时会静默落到系统 Qt，这行是唯一能当场发现的线索）：

```cmake
message(STATUS "使用的 Qt: ${Qt6_VERSION} @ ${Qt6_DIR}")
```

**Verify**：

```bash
rm -rf /tmp/pt-003 && cmake -B /tmp/pt-003 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF 2>&1 | grep "使用的 Qt"
```
→ 输出形如 `-- 使用的 Qt: 6.9.0 @ /Users/.../lib/cmake/Qt6`，且版本号 ≥ 6.7

```bash
cmake --build /tmp/pt-003 -j8
```
→ 退出码 0

```bash
cd /tmp/pt-003 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure
```
→ `100% tests passed, 0 tests failed out of 12`

### Step 3: 重写 `README.md` 的「构建」一节

把该节拆成「验证构建（不部署）」和「构建并部署」两块，验证放前面。
用下面的内容替换 `README.md` 中从 `## 构建` 到 `可选的 QML 静态检查：` 之前的全部内容
（`<Qt前缀>` 处填你在 Step 2 验证时实际打印出来的那个 Qt 前缀路径）：

```markdown
## 构建

需要先安装 Qt 6.7 或更高版本，并把 Qt 的 CMake 前缀传给 CMake。
不传 `CMAKE_PREFIX_PATH` 时 CMake 会落到系统里任意一个 Qt 上，配置阶段会打印实际使用的版本，
请照着确认一次。

### 验证构建（只想跑测试时用这个）

构建目录放在仓库外，并关闭自动部署，避免覆盖你正在用的 `/Applications/番茄Todo.app`：

```bash
cmake -B /tmp/pt-build -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-build -j8
cd /tmp/pt-build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure
```

### 构建并部署

日常要更新本机应用时用这个。构建结束会自动把最新包同步到固定入口：

```text
/Applications/番茄Todo.app
```

```bash
cmake -B /tmp/pt-build -S . -DCMAKE_PREFIX_PATH=<Qt前缀>
cmake --build /tmp/pt-build -j8
```

固定入口的存在是为了避免 LaunchServices 在临时构建目录里的 `.app` 和旧的
`/Applications/番茄Todo.app` 之间选错包。日常启动统一使用 `/Applications/番茄Todo.app`。
```

**Verify**：

```bash
grep -n "POMODORO_TODO_DEPLOY_LOCAL=OFF" README.md
```
→ 至少 1 处命中，且出现在「验证构建」段落里

```bash
grep -n "cmake -B build -S \." README.md
```
→ **无命中**（不再引导用户在仓库内建 build 目录）

```bash
grep -n "6.9.0" README.md
```
→ 无命中（不再把某个具体小版本写死成"验证版本"）

### Step 4: 校正 `docs/运行命令.md` 的测试规模与目标清单

**4a.** 先取到真实数字：

```bash
echo "ctest 目标数: $(grep -c 'add_test' CMakeLists.txt)"
echo "QML 测试文件数: $(ls tests/qml/tst_*.qml | wc -l | tr -d ' ')"
```

C++ 用例数（把每个测试类 `private slots:` 里非 fixture 的槽数加起来）：

```bash
grep -h "^\s*void [a-z][A-Za-z0-9_]*();" tests/*.cpp \
  | grep -vE "void (init|cleanup)(TestCase)?\(\);" | wc -l | tr -d ' '
```

**4b.** 把 `docs/运行命令.md:39` 那行注释里的数字换成上一步实测到的值，
并把「只跑单个测试目标」清单补全为当前所有 C++ 目标：

```bash
# 全套（<实测目标数> 个目标：C++ <实测用例数> 用例 + QML <实测文件数> 个测试文件）
ctest --test-dir <构建目录> --output-on-failure

# 只跑单个测试目标
./<构建目录>/PomodoroTodoTests        # 服务层主套件
./<构建目录>/CoreLogicTests           # 核心逻辑边界补充
./<构建目录>/RobustnessTests          # 健壮性与性能
./<构建目录>/CountdownServiceTests    # 倒计时服务
./<构建目录>/GoalServiceTests         # 长期目标服务
./<构建目录>/BackupServiceTests       # 备份与恢复
./<构建目录>/TimingRobustnessTests    # 计时健壮性（休眠/改钟）
./<构建目录>/PlatformControlTests     # 菜单栏与通知（平台无关层）
./<构建目录>/FontAssetsTests          # 字体资源
./<构建目录>/WallpaperAssetsTests     # 壁纸资源
./<构建目录>/ShaderAssetsTests        # Shader 资源
```

**4c.** 把该文件里所有硬编码的 `/Users/zerionlito/Qt/6.9.0/macos` 替换成占位符 `<Qt前缀>`，
并在文件开头（第 3 行那句说明之后）加一句：

```markdown
> `<Qt前缀>` 替换成本机 Qt 安装目录（例如 `~/Qt/6.9.0/macos` 或 `brew --prefix qt` 的输出）。
> 配置阶段会打印 `使用的 Qt: <版本> @ <路径>`，照着确认一次再往下走。
```

**4d.** 把该文件里出现的仓库内 `build` 目录改成仓库外目录（例如 `/tmp/pt-build`），
与 `AGENTS.md:44`「构建目录放在仓库外的临时目录」对齐。
`build-release` 同理改为 `/tmp/pt-release`。

**Verify**：

```bash
grep -n "8 个目标\|180 用例\|29 个" docs/运行命令.md
```
→ 无命中

```bash
grep -n "6.9.0" docs/运行命令.md
```
→ 无命中

```bash
grep -cn "GoalServiceTests\|BackupServiceTests\|TimingRobustnessTests\|PlatformControlTests" docs/运行命令.md
```
→ ≥ 4

```bash
grep -n "cmake -B build " docs/运行命令.md
```
→ 无命中

### Step 5: 全量回归

**Verify**：

```bash
rm -rf /tmp/pt-003
cmake -B /tmp/pt-003 -S . -DCMAKE_PREFIX_PATH=<Qt前缀> -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-003 -j8
cd /tmp/pt-003 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure
```
→ `100% tests passed, 0 tests failed out of 12`

并确认 `/Applications/番茄Todo.app` **未被本次验证构建改动**：

```bash
ls -ld /Applications/番茄Todo.app
```
→ 修改时间应早于本次执行开始的时间（说明 `DEPLOY_LOCAL=OFF` 生效了）

## Test plan

本计划不改运行时代码行为，因此**不新增单元测试**。验证靠的是构建系统层面的可执行检查：

- 护栏生效性：用非 `.app` 路径配置必须 FATAL_ERROR（Step 1 验证 2）。
- 护栏不误伤：合法 `.app` 路径必须配置成功（Step 1 验证 3）。
- Qt 下界生效性：配置阶段打印的版本必须 ≥ 6.7（Step 2）。
- 既有 12 个测试套件全绿（Step 5）——证明构建改动没有破坏任何目标。
- 文档准确性：Step 3、4 的 `grep` 断言。

## Done criteria

全部必须成立：

- [ ] `grep -n "/bin/rm" CMakeLists.txt` → 无命中
- [ ] `grep -n "find_package(Qt6 6.7 REQUIRED" CMakeLists.txt` → 1 处命中
- [ ] 用 `-DPOMODORO_TODO_LOCAL_APP_PATH=/tmp/not-an-app-bundle` 配置会 FATAL_ERROR，
      且错误信息包含 `必须指向一个 .app 应用包`
- [ ] `grep -n "POMODORO_TODO_DEPLOY_LOCAL \"" CMakeLists.txt` 显示默认值仍是 `ON`（**没有被改成 OFF**）
- [ ] `grep -n "cmake -B build -S \." README.md docs/运行命令.md` → 无命中
- [ ] `grep -n "6.9.0" README.md docs/运行命令.md` → 无命中
- [ ] `grep -n "8 个目标\|180 用例\|29 个" docs/运行命令.md` → 无命中
- [ ] `cd /tmp/pt-003 && ctest` → `100% tests passed ... out of 12`
- [ ] `/Applications/番茄Todo.app` 的修改时间未因本计划的验证构建而变化
- [ ] `git status --porcelain` 中本计划新增的改动只涉及 `CMakeLists.txt`、`README.md`、`docs/运行命令.md`
      （工作区可能已有其他未提交改动，那些不是你改的，不要动）
- [ ] `plans/README.md` 中 003 的状态行已更新

## STOP conditions

出现以下任一情况，停下来报告，不要自行发挥：

- Drift check 显示 in-scope 文件有改动，且 "Current state" 的摘录与实际内容对不上。
- Step 1 验证 2 中，非 `.app` 路径**配置成功了**（护栏没生效）。
- 本机安装的 Qt 版本低于 6.7 —— 加下界后会配置失败。报告实际版本，不要为了让它过就降低下界。
- `find_package(Qt6 6.7 ...)` 之后配置失败，且失败原因不是版本太低（例如某个组件找不到）。
- 全量测试在**改动之前**就不是 12 个套件全绿 —— 先报告基线状态。
- 你发现要让计划落地就必须把 `POMODORO_TODO_DEPLOY_LOCAL` 默认值改成 `OFF` ——
  那与 `AGENTS.md` 的既定工作流冲突，属于需要维护者拍板的决定，报告而不是自行决定。
- `git status` 显示你改动了 in-scope 之外的文件。

## Maintenance notes

- **未来交互点**：
  - 如果以后加 CI，CI 的构建**必须**传 `-DPOMODORO_TODO_DEPLOY_LOCAL=OFF`
    （CI runner 上没有 `/Applications/番茄Todo.app`，且 `lsregister` 不存在）。
    Step 3 重写后的 README「验证构建」段落可以直接抄成 CI 步骤。
  - 如果哪天要用 Qt 6.7 以下的 API 兼容性（不太可能），改下界前先确认
    `src/services/LogicalDay.h` 的 `TransitionResolution` 有替代写法。
- **评审重点**：
  1. `POMODORO_TODO_DEPLOY_LOCAL` 的默认值必须仍是 `ON` —— 本计划刻意不改它；
  2. 护栏用的是配置期 `message(FATAL_ERROR)` 而不是构建期检查，这样错误在
     `cmake -B` 那一步就暴露，还没轮到任何删除动作；
  3. 文档里的测试数字应该是**实测得到**的，不是抄本计划里的示例值。
- **本计划显式推迟的事项**：
  - `CMakeLists.txt` 里 `COMMAND /bin/sh -c "'${POMODORO_TODO_LSREGISTER}' -u '...' ..."`
    把路径拼进 shell 字符串。当前默认路径不含引号字符，未触发问题；改造它需要另一套
    `lsregister` 调用方式，收益低于风险，本计划不动。
  - 加 CI（GitHub Actions）不在本计划内，见 plans/README.md 的「已考虑」清单。
  - 开 `-Wall -Wextra` 不在本计划内：预计会一次性冒出几十条既有警告，需要单独一轮清理。
