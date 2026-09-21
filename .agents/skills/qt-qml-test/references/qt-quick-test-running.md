# Qt Quick Test 执行与诊断

路径和环境取自 `AGENTS.md`、现有 CMake 配置和测试脚本；下列尖括号需要替换为已确认的路径。Qt 工具与构建产物使用同一套兼容的 Qt 安装。

## 选择执行入口

| 当前条件 | 执行方式 |
|---|---|
| 已有 CTest 或专用测试二进制 | 复用其链接、注册、路径和测试环境 |
| 纯 QML，依赖可从磁盘或动态插件加载 | qmltestrunner，设置必要的 import 路径 |
| 依赖静态 QML 插件或 C++ 服务注册 | 已有或最小新增的 C++ 测试宿主 |
| 模块挂在应用 executable 上 | 核实测试如何获得同一注册与资源，不假设存在可加载插件 |

- 静态模块不能仅靠增加 import 搜索路径变成动态插件；检查链接、插件导入和注册是否生效。
- 可执行目标上的 QML 模块通常没有独立插件。优先项目测试装配，不把拆分模块当唯一修复。
- 测试真正实例化需要 QApplication 的依赖时使用适配的宿主；不能仅因工程链接 Widgets 就判定所有测试都必须更换宿主。
- 修改 CMake 接线时使用 `qt-cmake-project`，但不为直接可运行的测试引入新的构建层。
- 使用 `QUICK_TEST_MAIN_WITH_SETUP` 等已有机制初始化服务、应用标识与测试路径；它们需要在被测依赖创建前生效。

## 执行命令

先从项目配置确定 `<build-dir>`、目标和用例名称，环境采用项目规定的无显示设置。

```bash
cmake --build "<build-dir>" --target "<test-target>"
ctest --test-dir "<build-dir>" -R "<test-pattern>" --output-on-failure
```

只有需要逐 QML 用例结果时，才直接调用测试二进制或 qmltestrunner 写出 JUnit：

```bash
"<test-binary>" -o "<report.xml>,junitxml"
"<qt-bin>/qmltestrunner" -input "<tests-path>" -import "<qml-import-root>" -o "<report.xml>,junitxml"
python3 "<skill-dir>/references/scripts/parse-qmltestrunner-output.py" "<report.xml>"
```

- CTest 的 JUnit 通常以注册测试目标为粒度；需要 QML 函数粒度时使用 Qt Test 自身输出。不要混用两个总数。
- runner 会搜索输入目录中的子目录，事先核对实际范围；选择文件或叶目录排除无关用例，不擅自重命名用户测试。
- 为本次运行使用新报告路径，防止失败后误读旧报告；报告放在项目允许的产物目录。
- 无显示运行环境通过测试进程或 CTest 的环境配置传入，不给 CTest 传 Qt 的 `-platform` 参数。

## 结果解释

- 保留测试退出码与 stderr。非零退出且报告有效时仍可解析诊断，但不能据解析器返回 0 宣称成功。
- 解析脚本返回 `total/passed/failed/skipped/duration_ms/cases/slowest`；返回含 `error` 的对象或非零退出时报告解析失败。
- `No testcase`、文件缺失、XML 不完整分别检查用例发现、输出路径、崩溃或中断。
- `Type unavailable`、模块缺失、qrc 路径错误先核实导入、注册、资源与环境，不能立即认定需要重构应用。
- 跳过与未发现用例都不是通过；报告执行范围与排除项。
- 失败归因需要断言、日志或可复现路径。源文件 mtime 不证明代码引入了回归。
- 仅在用户要求保存报告时补可复现命令、环境、失败和限制；无须固定章节或每轮生成一份文档。
