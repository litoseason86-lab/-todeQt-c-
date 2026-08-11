# 番茄Todo

面向考研复习的本地桌面应用。核心流程是先创建任务，再从任务启动专注计时，最后沉淀本地统计数据。仅面向 macOS，使用原生菜单栏与通知能力，数据全部保存在本地、不联网。

## 功能

- **任务管理**：今日任务清单、本周计划、每日例行（可编辑、跨天自动生成）、逾期结转、分类管理。
  任务可写备注（页码、题号等上下文），任务行单行省略显示。今日列表内可拖动排序（手动序优先，
  没排过的回落到创建时间）；本周计划里可把任务拖到另一天改期（落在目标日末尾），
  不再受编辑弹窗「今天/明天/后天」只能挪两天的限制。
- **专注计时**：番茄工作法（工作—休息循环，支持长休息）与自由正向计时；沉浸模式；自由计时超过设定小时数后结束需确认记录或丢弃。
- **预计用时口径**：任务可设「预计用时」（小时+分钟，与今日专注目标同一个输入组件），实际投入由专注记录自动累计（不冗余存储）；专注时长达到预计用时可自动完成任务。累计时长对计时模式不敏感（番茄段与自由计时都算），番茄段另按「有效番茄」这一全局唯一口径计数。
  今日任务页的目标条同时给出「已排」（当天任务预计用时之和）与它跟今日目标的差额，
  排完就知道是排多了还是排少了；未设目标时只报总量，不做判断。
- **专注记录可修改**：忘记开计时、中途强退、计时器绑错任务，都能在专注历史页补录、修改或删除。
  补录记为自由计时（不伪装成完整番茄），但照常计入专注分钟，因而对任务预计用时和长期目标进度
  都有效。拦重叠时间段（两条覆盖同一段会让统计凭空多出时长）、拦未来时间、拦低于 3 分钟有效门槛，
  也拒绝改动正在进行的会话。
- **数据统计**：今日/本周/本月概览、科目时间分配、趋势图、每周复盘（计划用时 vs 实际投入的确定性偏差分析）。仪表盘任务面板有「全部 / 已完成 / 学习统计」三态筛选，「学习统计」按任务列出当天专注时长与番茄数（未绑定任务的自由计时汇成「未关联专注」一行）。
- **长期目标与奖励机制**：目标以「投入分钟」计量（与任务预计用时同一把尺子，输入组件也是同一个），
  进度口径是有效专注分钟——番茄段与自由计时都算。目标列表（列表/网格双版式）在卡片上直接给出
  科目、进度条与「来得及 / 偏慢 N 天 / 已超期 N 天 / 长期 / 暂无预测」的结论；详情页 100 格进度、
  月历热力（深浅同样按分钟）、完成预测；跨 25/50/75/100% 触发全局 Toast、里程碑弹窗、粒子与音效
  （沉浸模式压弹窗，`reduceMotion` 全程可降级）。
- **目标倒计时**。
- **外观**：7 套主题壁纸（暖色 / 粉色 / 烟雨江南 / 雪岭剑影 4 浅 + 星空 / 雨夜窗景 / 月夜山影 3 深），整套 UI 语义色板随主题切换；玻璃质感只用于导航栏、浮动工具栏与弹窗，内容卡保持清晰；全局 `reduceMotion` 可关闭动效。
- **设置中心**：通用 / 专注 / 外观 / 数据 / 关于五页，含每日专注目标、逻辑日起始时间（`dayStartHour`，凌晨记账算前一天）。
- **计时健壮性**：跨系统休眠、锁屏、系统时间变化仍能正确计时（基于 `mach_continuous_time`）。
- **macOS 原生集成**：菜单栏倒计时（`NSStatusItem`）+ 阶段完成系统通知（`UNUserNotificationCenter`）；关闭主窗口可最小化到菜单栏。
- **快捷键**：18 个动作全部可自定义（设置中心「快捷键」分页录制改键、冲突检测、单行/整体恢复默认、可停用）。
  应用内 15 个开箱即用：⌘1–⌘8 切页、⌘N 新建任务、⌘↩ 开始/暂停专注、⌘⇧↩ 结束专注、
  ⌘⇧F 沉浸模式、⌘\ 侧栏、⌘, 设置、⌘/ 快捷键速查。应用内键位**可以只用一个键**（空格、数字键等）：
  焦点在输入框时无修饰键的快捷键自动让路，带 ⌘/⌃/⌥ 的照常可用；弹窗接管焦点时整体让路，不会在弹窗背后误切页。
  另有 3 个全局热键（开始/暂停、结束专注、召回/隐藏窗口）走 Carbon `RegisterEventHotKey`，
  应用在后台也能触发且**不需要辅助功能授权**——但**出厂不占用任何系统按键**，
  需要时在设置里自行指定（预设键位难免和已装的其他应用撞车，而撞车表现是别的应用那个键失灵，很难排查）。
- **数据安全**：单文件备份与恢复（`.tomatobackup`，含自动备份与失败回滚）、CSV 导出；删除/完成任务提供撤销。

## 技术栈

- Qt 6
- Qt Quick/QML
- C++17
- SQLite
- CMake

## 构建

需要先安装 Qt 6.7 或更高版本，并使用该 SDK 自带的 `qt-cmake`。
本机已验证的工具是 `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake`；它会同步设置
Qt SDK 支持的 macOS 部署下界。不要用当前 Homebrew Qt 构建部署包：其 Qt Quick 框架最低要求
macOS 26，会让应用二进制和链接框架的部署版本不一致。

### 验证构建（只想跑测试时用这个）

构建目录放在仓库外，并关闭自动部署，避免覆盖你正在用的 `/Applications/番茄Todo.app`：

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -B /tmp/pt-audit -S . -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-audit -j8
QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
  ctest --test-dir /tmp/pt-audit --output-on-failure --timeout 240
```

**两种构建必须用不同的构建目录**（这里是 `/tmp/pt-audit`，下面是 `/tmp/pt-build`）。
`POMODORO_TODO_DEPLOY_LOCAL` 是 CMake cache 变量，会持久化在构建目录里：在同一个目录先跑验证构建再跑部署构建，
`OFF` 仍然生效，`deploy-local-app` 目标根本不会被创建，部署会静默失效。

测试规模（2026-08-08 实测，Qt 6.9.0）：**18 个 ctest 目标全绿，约 68 秒**——
16 个 C++ 目标共 329 个测试函数，`PomodoroTodoQmlTests` 覆盖 `tests/qml/` 的 36 个文件、476 条断言函数；
另有 `QmlLintGate` 一条 QML 静态检查门禁（unqualified 与 layout-positioning 零容忍）。
单个目标的跑法与说明见 `docs/运行命令.md`。

### 构建并部署

日常要更新本机应用时用这个。构建结束会自动把最新包同步到固定入口：

```text
/Applications/番茄Todo.app
```

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -B /tmp/pt-build -S .
cmake --build /tmp/pt-build -j8
```

固定入口的存在是为了避免 LaunchServices 在临时构建目录里的 `.app` 和旧的
`/Applications/番茄Todo.app` 之间选错包。日常启动统一使用 `/Applications/番茄Todo.app`。
部署脚本（`cmake/DeployLocalApp.cmake`）的顺序是：复制到暂存目录 → 校验主二进制存在 →
把旧包改名备份 → 原子 rename 换上新包 → 清理备份并刷新 `lsregister`；任一步失败都会把旧包放回原位。

构建对应用与全部测试目标开启 `-Wall -Wextra`（`pomodoro_todo_enable_warnings`），
当前实测 0 警告；没开 `-Werror`，单条告警不阻断本地开发。

可选的 QML 静态检查（用目标 Qt SDK 自带的 `qmllint`，不要用 PySide6 工具链）：

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint -I qml \
  qml/*.qml qml/views/*.qml qml/components/*.qml qml/components/settings/*.qml
```

**它现在是门禁**：ctest 条目 `QmlLintGate` 对 `unqualified` 与 `Quick.layout-positioning` 零容忍
（两者均已清零），只显式豁免 `missing-property` 与 `use-proper-function` 两类——
前者是 qmllint 推导不到运行时类型的工具限制，后者是项目既定的回调注入模式。
上面那条手工命令用于查看全部告警；门禁判据以 CMake 里的 `QmlLintGate` 为准。

## 项目结构

```text
src/models/            数据模型
src/services/          C++ 服务层（跨平台业务逻辑）
src/platform/macos/    macOS 原生层（菜单栏 NSStatusItem、通知 UNUserNotificationCenter、全局热键 Carbon，Objective-C++）
qml/                   QML 界面（views/ 页面、components/ 组件、components/settings/ 设置面板）
resources/             Qt 资源文件（字体、壁纸、音效）
shaders/               预编译 Shader 资源
cmake/                 构建脚本（DeployLocalApp.cmake：部署到 /Applications 的原子切换逻辑）
tests/                 Qt Test 自动化测试（C++ 用例 + tests/qml/ 的 Qt Quick Test）
docs/                  运行命令与专题方案；superpowers/ 为历史归档（只保留设计规格 specs/）
plans/                 只有 README.md：执行状态索引与历次审计记录（编号计划正文已执行完毕并删除）
```

业务逻辑（标准 C++/Qt）与 macOS 原生代码（`.mm`）保持分离：`src/services` 只依赖平台无关抽象，原生实现放在 `src/platform/macos`。

## 几条贯穿全局的口径

改动这些地方前先读这一节——它们每一条都有对应的测试守着，绕过去会在别处炸。

- **有效专注的两个口径，定义只有一份**，都在 `src/services/FocusSessionRules.h`：
  `validPomodoroCountExpr` 数「完整番茄」（番茄模式 + 自然到点 + 达到 3 分钟门槛），
  `focusedSecondsExpr` 累「有效专注秒数」（对计时模式不敏感，两种计时都算）。
  两者回答的问题不同，但都不允许在别处复制出第二套阈值或模式判断。
  任务预计用时、长期目标进度、月历热力全部走后者。
- **时长单位统一为分钟**，任务预计用时、今日专注目标、长期目标三处同一把尺子，
  输入控件也是同一个 `qml/components/DurationFieldPair.qml`，展示统一走 `qml/Duration.js`。
- **逻辑日**：一天从 `dayStartHour`（默认 4 点）开始，凌晨记账算前一天。
  任何日期比较都必须走 `LogicalDay`，包括测试——用 `new Date()` 的物理日期写用例，
  白天跑碰巧过、凌晨必红。
- **控件颜色必须接管 palette**：Qt Quick Controls 从 `palette` 取输入框正文/占位/选区、
  下拉面板底与选项行、以及没显式写 `color` 的 `Label`，而 Basic 风格的默认值是写死的浅色，
  既不跟随本应用主题也不跟随 macOS 外观。窗口层（`main.qml`/`MainWindow.qml`）已兜底，
  各弹窗再写一份是为了单独实例化时（离屏走查、QML 测试）也准确。
  `tests/qml/tst_contrast_audit.qml` 会遍历八个视图 × 明暗两套主题，按 WCAG 门槛
  实算每个文字项的对比度，零例外。
- **恢复备份只写回自己拥有的键**。备份文件是外部输入（可能来自别的版本、被手工改过、
  或者伪造）。过滤按 `AppSettings::ownedSettingGroups()` 的**顶层分组**做，不是逐键列举——
  快捷键覆盖是 `shortcuts/<actionId>` 这样的动态键，扁平白名单会把用户改过的键位全丢掉，
  那比不过滤更糟。**新增一个设置分组时必须同步那份清单**，
  `everySettingTheAppWritesPassesTheOwnershipFilter` 会遍历应用真实写出的每个键做交叉验证，
  漏加当场转红并指名是哪个键。
- **schema 迁移**：版本号在 `DatabaseManager::kCurrentSchemaVersion`，每一步除版本号外
  还带结构检查（列缺失时无论版本号都补），防御半迁移状态。
  **给 `tasks` 新增列时必须同步 `migrateToVersion5` 的 `knownColumns` 与建表语句**——
  那是整表重建，漏列会静默清空该列的用户数据（历史上已经栽过一次）。
