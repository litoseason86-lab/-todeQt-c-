# 模块依赖检查

- 区分 CMake 目标名、QML URI、输出目录和运行时资源路径，它们不是同一个标识。
- 实现依赖用 PRIVATE；公共头文件实际暴露的依赖才向消费者传递。INTERFACE 适用于仅向消费者提供的要求。
- add_subdirectory 的顺序应让依赖目标可见，避免用全局 include/link 路径掩盖依赖缺失。
- QML backing target 包含实现；plugin target 服务于加载。静态模块检查消费者是否链接并导入所需插件。
- 挂在 executable 上的 QML 模块不会自动提供独立插件；测试或其他消费者需有自己的注册/链接方案。
- 不为增加一个测试而自动拆分应用模块；先检查现有装配方式和最小可行改动。
- 改变目标类型、URI 或资源前缀可能影响消费者；追踪实际使用点并验证。

具体参数按项目 Qt 版本查 [qt_add_qml_module](https://doc.qt.io/qt-6/qt-add-qml-module.html)。
