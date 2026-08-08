# 番茄Todo

面向考研复习的本地桌面应用。核心流程是先创建任务，再从任务启动专注计时，最后沉淀本地统计数据。仅面向 macOS，使用原生菜单栏与通知能力，数据全部保存在本地、不联网。

## 功能

- **任务管理**：今日任务清单、本周计划、每日例行（可编辑、跨天自动生成）、逾期结转、分类管理。
- **专注计时**：番茄工作法（工作—休息循环，支持长休息）与自由正向计时；沉浸模式；自由计时超过设定小时数后结束需确认记录或丢弃。
- **番茄口径**：任务可设预估番茄数，实际番茄由专注记录自动累计（不冗余存储）；达到预估番茄目标可自动完成任务。「有效番茄」为全局唯一口径。
- **数据统计**：今日/本周/本月概览、科目时间分配、趋势图、每周复盘（计划 vs 实际的确定性偏差分析）。仪表盘任务面板有「全部 / 已完成 / 学习统计」三态筛选，「学习统计」按任务列出当天专注时长与番茄数（未绑定任务的自由计时汇成「未关联专注」一行）。
- **长期目标与奖励机制**：目标列表（列表/网格双版式）、详情页 100 格进度与月历热力、完成预测；跨 25/50/75/100% 触发全局 Toast、里程碑弹窗、粒子与音效（沉浸模式压弹窗，`reduceMotion` 全程可降级）。
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

测试规模（2026-08-08 实测，Qt 6.9.0）：**17 个 ctest 目标全绿，约 71 秒**——
16 个 C++ 目标共 324 个测试函数，`PomodoroTodoQmlTests` 覆盖 `tests/qml/` 的 34 个文件、467 条断言函数。
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

注意它目前**不是门禁**：2026-08-07 实测输出 259 条警告（其中 250 条 `[unqualified]`）但退出码仍为 0，清理计划见 `plans/029`。

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
docs/                  运行命令与专题方案；superpowers/ 为历史归档（只保留设计规格）
plans/                 编号实施计划（plans/README.md 是执行状态索引）
```

业务逻辑（标准 C++/Qt）与 macOS 原生代码（`.mm`）保持分离：`src/services` 只依赖平台无关抽象，原生实现放在 `src/platform/macos`。
