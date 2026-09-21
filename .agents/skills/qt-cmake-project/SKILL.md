---
name: qt-cmake-project
description: 新增或修改 Qt 6 CMake 目标、QML 模块、资源和测试接线，或排查相关配置及构建错误时使用。保留现有工程结构，不自动迁移与任务无关的构建写法。
license: LicenseRef-Qt-Commercial OR BSD-3-Clause
metadata:
  author: qt-ai-skills
  version: "1.0.1"
  qt-version: "6.x"
  category: conceptual
  project-revision: "2"
---

# Qt CMake 工程维护

先读取适用的 `AGENTS.md`、相关 CMake 文件及已有 presets/cache。构建目录、验证与部署的区别、部署目标和启动权限由项目规则决定，不在这里硬编码。

## 变更边界

- 优先修改已有目标和资源声明，保持目录分层与命名；不顺手添加安装、发布或新测试框架。
- 现有可工作结构不是待迁移缺陷。仅在它阻碍本次目标或存在已确认错误时做最小调整。
- 不仅凭版本号或个人偏好升级 Qt/CMake、改变 QML URI、资源前缀、目标类型或目录布局。
- 改动前确认项目实际 Qt 版本及策略设置；不确定的参数查该版本官方文档，不猜选项名。

## 核心检查

- 为 Qt 6 使用项目已有的 `qt_*` 或 `qt6_*` 命令约定；后者在禁用无版本命令的项目中有用途。
- 确认 AUTOMOC 等目标属性生效。已有手工配置不需要仅为引入 `qt_standard_project_setup()` 而迁移。
- 新增 QML 模块优先使用 `qt_add_qml_module()`，正确区分 `QML_FILES`、`SOURCES` 和 `RESOURCES`。
- QML 单例和资源别名等源文件属性需在模块消费它们之前设定。
- 链接依赖按使用者选择 `PRIVATE`、`PUBLIC` 或 `INTERFACE`；测试依赖不无意进入应用接口。
- 生成的 moc、qmldir、qmltypes、资源和 shader 二进制由构建系统管理，不手工修改生成物。
- 同时检查运行时模块/资源加载和构建时注册；编译成功不代表路径正确。

## 按需参考

- 新增单目标工程或启动配置：[基本目标边界](references/simple-project.md)。
- 多目标依赖或静态插件：[模块依赖](references/modular-architecture.md)。
- 新增 QML、单例或注册类型：[QML 集成](references/qml-integration.md)。
- 图片、翻译、字体、shader：[资源](references/resources.md)。
- 配置、构建、cache 冲突：[构建诊断](references/configure.md)。
- 出现注册或路径错误时：[常见故障核对](references/common-mistakes.md)。

只读取相关参考，不要求每次遍历全部文件。

## 验证

- 配置后构建受影响目标，按项目规定运行相关测试。
- 添加/删除 QML import 可能需要重新配置，不能假设只重编译就会刷新所有导入信息。
- 构建失败时处理当前错误，不使用旧产物冒充成功；部署与产物校验遵守项目规则。
- 报告具体目标及验证结果，不将构建、部署和启动混为一步。
