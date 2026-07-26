# 番茄Todo

面向考研复习的本地桌面应用。核心流程是先创建任务，再从任务启动专注计时，最后沉淀本地统计数据。

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
cd /tmp/pt-build && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure
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
src/models/       数据模型
src/services/     C++ 服务层
qml/              QML 界面
resources/        Qt 资源文件
tests/            Qt Test 自动化测试
docs/             设计与开发计划
```
