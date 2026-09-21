# QML 模块、单例与注册

- 新增 QML 文件加入已有模块的 QML_FILES；C++ 类型源文件和静态资源分别进入对应参数。
- 单例同时核对 QML 的 `pragma Singleton` 和 CMake 的 `QT_QML_SINGLETON_TYPE`；源文件属性在模块声明消费它之前设置。
- 资源别名 `QT_RESOURCE_ALIAS` 同样在添加文件前设置，改动后检查加载路径。
- URI、OUTPUT_DIRECTORY、RESOURCE_PREFIX 和 Qt 策略共同决定查找；目录警告不等于必然运行失败。
- 可执行目标作为 backing target 时与库模块的布局要求不同，不能机械要求全部源目录匹配 URI。
- TARGET 形式的模块依赖等新选项先核对当前 Qt 版本及策略，不能默认所有 Qt 6 都支持。
- QML_ELEMENT 等声明依赖构建时扫描和注册；核对 AUTOMOC、头文件可见性及 QtQml 依赖。
- 不编辑自动生成的 qmldir/qmltypes；确有手工注册或手工 qmldir 的项目保留其契约。
- 使用 loadFromModule、URL 或相对导入时分别核对实际资源位置；改前缀前搜索消费者。
- import 变化后必要时重新配置，检查生成导入信息和静态插件链接是否刷新。

命令参数与版本差异查 [官方模块文档](https://doc.qt.io/qt-6/qt-add-qml-module.html)。
