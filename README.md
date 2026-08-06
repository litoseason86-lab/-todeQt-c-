# 番茄Todo

面向考研复习的本地桌面应用。核心流程是先创建任务，再从任务启动专注计时，最后沉淀本地统计数据。仅面向 macOS，使用原生菜单栏与通知能力，数据全部保存在本地、不联网。

## 功能

- **任务管理**：今日任务清单、本周计划、每日例行（可编辑、跨天自动生成）、逾期结转、分类管理。
- **专注计时**：番茄工作法（工作—休息循环，支持长休息）与自由正向计时；沉浸模式；自由计时超过设定小时数后结束需确认记录或丢弃。
- **番茄口径**：任务可设预估番茄数，实际番茄由专注记录自动累计（不冗余存储）；达到预估番茄目标可自动完成任务。「有效番茄」为全局唯一口径。
- **数据统计**：今日/本周/本月概览、科目时间分配、趋势图、每周复盘（计划 vs 实际的确定性偏差分析）；仪表盘「学习统计」分段按任务列出当天专注时长。
- **长期目标与奖励机制**、**目标倒计时**。
- **计时健壮性**：跨系统休眠、锁屏、系统时间变化仍能正确计时（基于 `mach_continuous_time`）。
- **macOS 原生集成**：菜单栏倒计时（`NSStatusItem`）+ 阶段完成系统通知（`UNUserNotificationCenter`）；关闭主窗口可最小化到菜单栏。
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
/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -B /tmp/pt-build -S . -DPOMODORO_TODO_DEPLOY_LOCAL=OFF
cmake --build /tmp/pt-build -j8
cd /tmp/pt-build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure --timeout 240
```

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

可选的 QML 静态检查：

```bash
pyside6-qmllint qml/main.qml qml/MainWindow.qml qml/views/TodayTaskView.qml qml/views/FocusView.qml qml/components/Sidebar.qml qml/components/TaskItem.qml qml/components/AddTaskDialog.qml
```

## 项目结构

```text
src/models/            数据模型
src/services/          C++ 服务层（跨平台业务逻辑）
src/platform/macos/    macOS 原生层（菜单栏 NSStatusItem、通知 UNUserNotificationCenter，Objective-C++）
qml/                   QML 界面
resources/             Qt 资源文件
tests/                 Qt Test 自动化测试
docs/                  设计与开发文档
plans/                 编号实施计划（历史执行记录）
```

业务逻辑（标准 C++/Qt）与 macOS 原生代码（`.mm`）保持分离：`src/services` 只依赖平台无关抽象，原生实现放在 `src/platform/macos`。
