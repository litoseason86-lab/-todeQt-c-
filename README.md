# 番茄Todo

面向考研复习的本地桌面应用。核心流程是先创建任务，再从任务启动专注计时，最后沉淀本地统计数据。

## 技术栈

- Qt 6
- Qt Quick/QML
- C++17
- SQLite
- CMake

## 构建

需要先安装 Qt 6 SDK，并把 Qt 的 CMake 前缀传给 CMake。当前验证使用的是 Qt 6.9.0：

```bash
cmake -B build -S . -DCMAKE_PREFIX_PATH=/Users/zerionlito/Qt/6.9.0/macos
cmake --build build
ctest --test-dir build --output-on-failure
```

如果 Qt 安装在其他位置，把 `CMAKE_PREFIX_PATH` 改成对应的 Qt 安装目录。

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
