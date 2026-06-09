# 番茄Todo

面向考研复习的本地桌面应用。核心流程是先创建任务，再从任务启动专注计时，最后沉淀本地统计数据。

## 技术栈

- Qt 6
- Qt Quick/QML
- C++17
- SQLite
- CMake

## 构建

```bash
cmake -B build -S .
cmake --build build
ctest --test-dir build --output-on-failure
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
