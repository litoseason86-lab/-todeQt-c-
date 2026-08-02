# Plan 019: 为 v8 完整番茄口径变更增加一次性说明

> **Executor instructions**: 严格按步骤和 UI 契约实现。完成后更新索引；触发 STOP 条件时不要自行重做迁移或资源体系。
>
> **Drift check（先执行）**：
>
> ```bash
> git diff --stat 52726d9..HEAD -- src/services/DatabaseManager.h src/services/DatabaseManager.cpp src/services/AppSettings.h src/services/AppSettings.cpp src/main.cpp qml/main.qml qml/components/NaturalCompletionNoticeDialog.qml resources/qml.qrc tests/ServiceTests.cpp tests/qml/tst_natural_completion_notice.qml
> ```

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: migration / docs
- **Planned at**: commit `52726d9`, 2026-07-29

## Why this matters

维护者已经决定保留 v8 的历史兼容回填：旧记录按“番茄模式、已结束、至少 3 分钟”推定为完整番茄；升级后只有自然到点才算完整番茄。这个决定不可逆且升级前后口径不同，不提示就会让用户把数字变化误判为数据丢失。本计划只落实一次性、可理解的产品说明，不重写迁移语义。

## Current state

- `plans/README.md` 的“需要维护者拍板的产品问题”已记录决策 (a)：保留 v8 回填，并加发布说明与应用内一次性提示。
- `AppSettings` 已有 `closeToTrayHintShown` 一次性布尔设置模式：Q_PROPERTY、getter/setter、changed signal、`reload()` 广播。
- `qml/main.qml` 是启动装配层；现有首次隐藏通知只在投递成功后写 `closeToTrayHintShown`。
- `DatabaseManager::initialize()` 在创建目录后打开/迁移数据库，但没有暴露“本次启动打开前文件是否已存在”。
- 当前窗口基线：macOS 桌面、1024×768、最小 860×620，Qt Quick Controls Basic 测试风格；主要语言中文，鼠标与键盘都必须可用。
- 项目仍使用历史 `resources/qml.qrc`，并由 `QmlResourceManifestTests` 校验所有 QML 源均登记。不要在本计划中迁移整个项目到 `qt_add_qml_module`；那是独立架构工作。

### 文案契约

- 标题：`完整番茄计数规则已更新`
- 正文：`升级后，只有自然计时到点的番茄会计入番茄数量、长期目标和相关统计。手动提前停止仍会保留专注时长，但不计为完整番茄。历史记录已按兼容规则保留，因此升级日前后的数字口径可能不同。`
- 主按钮：`知道了`
- 只在“启动时数据库文件已存在且设置未确认”时显示；全新安装不显示。
- 只有用户明确按下“知道了”才持久化；窗口出现本身、Escape 或应用退出不能写已确认。

## Commands you will need

| 用途 | 命令 | 成功预期 |
|---|---|---|
| 配置 | `/Users/zerionlito/Qt/6.9.0/macos/bin/qt-cmake -S . -B /tmp/pt-019 -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPOMODORO_TODO_DEPLOY_LOCAL=OFF` | exit 0 |
| 编译 | `cmake --build /tmp/pt-019 -j8` | exit 0 |
| 后端测试 | `cd /tmp/pt-019 && ctest -R '^(PomodoroTodoTests|QmlResourceManifestTests)$' --output-on-failure` | 2/2 通过 |
| QML 测试 | `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_natural_completion_notice.qml -import qml -import qml/components` | 通过，无窗口 |
| 全量 | `cd /tmp/pt-019 && QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic ctest --output-on-failure` | 全部通过 |

## Suggested executor toolkit

- 使用 `qt-qml`：独立对话框、Loader 生命周期、绑定和测试写法。
- 使用 `qt-ui-design`：桌面模态层、键盘、44px 命中区、对比度和可访问性。
- 若改动 CMake/资源装配，使用 `qt-cmake-project`；本计划默认沿用既有 `.qrc`，不得顺手做全量模块迁移。

## Scope

**In scope**：

- `src/services/DatabaseManager.h/.cpp`
- `src/services/AppSettings.h/.cpp`
- `src/main.cpp`
- `qml/main.qml`
- `qml/components/NaturalCompletionNoticeDialog.qml`（新建）
- `resources/qml.qrc`
- `tests/ServiceTests.cpp`
- `tests/qml/tst_natural_completion_notice.qml`（新建）

**Out of scope**：v8/v9 SQL 与 schema version；历史记录重算；第三种完成状态；发布网站/商店文案；把所有 QML 迁到 `qt_add_qml_module`；任何动画或音效；根据“是否有历史会话”做额外 SQL 查询。

## Git workflow

- 分支：`advisor/019-v8-counting-notice`
- 中文提交信息：`增加完整番茄口径一次性说明`
- 不 push，不开 PR。

## Steps

### Step 1: 先创建文件框架和红灯测试

先创建 `NaturalCompletionNoticeDialog.qml` 与对应 QML 测试文件，仅放必要 imports、根类型、公开 `acknowledged` signal 和测试 TestCase 框架；把新组件登记进 `resources/qml.qrc`，避免中途资源清单断裂。

先写测试：

- AppSettings 新键默认 false、写 true 后跨实例保持、`reload()` 发 signal。
- 新数据库首次 initialize 的 `openedExistingDatabase()` 为 false；关闭后同路径重开为 true。
- QML 对话框正文含“自然计时到点”“手动提前停止”“历史记录”，主按钮可由键盘激活并只发一次 `acknowledged`；Escape 不发 acknowledged。

禁止断言 `visible === true`；使用组件属性、SignalSpy、`tryCompare`。

**Verify**：AppSettings/DatabaseManager API 未实现前 C++ 测试编译失败；QML 组件未完整实现前行为测试失败。若全部直接通过，STOP。

### Step 2: 记录启动时数据库是否已存在

在 `DatabaseManager` 增加只读 `bool openedExistingDatabase() const` 与成员。`initialize(path)` 在任何创建/打开动作之前用最终绝对路径的 `QFileInfo::exists()` 取值；只有 initialize 成功后才提交该标志，失败不能覆盖上一次成功事实。补中文注释说明它是启动教育提示的上下文，不是 schema 判断。

同路径已打开的快速分支也必须有明确语义：重入 initialize 不应把原本的新建启动改成“旧安装”。建议保存“本次成功打开前”的事实，主程序只在首次 initialize 后读取；测试锁住该规则。

**Verify**：相关 C++ 测试通过。

### Step 3: 增加一次性设置键

按 `closeToTrayHintShown` 模式增加 `naturalCompletionNoticeShown`：

- key：`migration/v8NaturalCompletionNoticeShown`
- 默认 false；相同值不写、不发 signal；写失败沿用 `settingsWriteFailed`。
- `reload()` 必须发对应 changed signal。

**Verify**：设置 round-trip、去重 signal 和 reload 测试通过。

### Step 4: 实现独立、可访问的说明对话框

`NaturalCompletionNoticeDialog.qml` 使用项目现有 Dialog/GlassPanel 视觉模式和 Theme 语义令牌，不硬编码颜色。要求：

- 模态但不嵌入 `main.qml` 的多层 UI；正文可换行，860×620 下不截断。
- `知道了` 是唯一 CTA，最小高度 44px，`activeFocusOnTab: true`，有明确焦点态；内置 Button 的 Accessible.name 与文本一致。
- Escape 只关闭/拒绝，不发 `acknowledged`；主按钮点击或 Enter/Space 发一次 acknowledged 后关闭。
- 无装饰动画；因此无需新增 reduceMotion 分支。
- 所有用户可见字符串用 `qsTr()`。

**Verify**：QML 定向测试通过；`QmlResourceManifestTests` 通过。

### Step 5: 在启动装配层用 Loader 控制一次性生命周期

`main.cpp` 在首次数据库 initialize 成功后计算布尔上下文属性：

```text
openedExistingDatabase && !AppSettings::naturalCompletionNoticeShown()
```

命名为 `naturalCompletionNoticeRequired` 并注入 QML。`qml/main.qml` 使用 `Loader` 条件加载独立对话框，`active: naturalCompletionNoticeRequired && !appSettings.naturalCompletionNoticeShown`。Loader Ready 后再 open；访问 `loader.item` 必须守卫 `status === Loader.Ready`。

收到 `acknowledged` 后先写 setting；只有 getter 确认已经持久化为 true 才停用 Loader。写失败时保持对话框可再次确认，并通过 `mainContent.showToast` 显示失败，不能假装已确认。

**Verify**：应用目标编译；QML 测试覆盖 acknowledged 后 Loader 条件关闭、Escape 后设置仍 false。

### Step 6: 全量回归与资源审计

**Verify**：全量测试全绿；`git diff --check` 无输出；`QmlResourceManifestTests` 证明组件已登记；不启动、不部署应用。

## Test plan

- 新/旧数据库文件识别，initialize 失败不污染标志。
- 设置默认值、持久化、相同值不重复发信号、reload。
- 文案完整、键盘确认、Escape 不确认、acknowledged 单次发射。
- Loader 条件：全新安装不加载，旧库未确认加载，确认后不再加载。
- 资源清单与全量 QML/C++ 回归。

## Done criteria

- [ ] 新安装不显示，既有数据库且未确认时显示。
- [ ] 文案精确解释升级后、手动停止与历史兼容三件事。
- [ ] 只有明确确认成功写盘后才永久关闭提示。
- [ ] 对话框独立成文件，支持键盘/Escape，使用 Theme 与 `qsTr()`。
- [ ] C++、QML、资源清单和全量测试全绿。
- [ ] 没有修改迁移 SQL、schema 或资源架构。
- [ ] 019 状态行已更新。

## STOP conditions

- 维护者决策已从 (a) 改为重算历史或第三状态。
- 无法在首次 initialize 前可靠判断数据库文件是否存在。
- 实现要求读取用户历史内容或改变数据库 schema。
- 项目已迁移到 `qt_add_qml_module`，`.qrc` 摘录不再成立。
- 需要启动真实 GUI 才能验证自动化契约。

## Maintenance notes

- 这是 release/migration notice，不是通用 onboarding。未来改文案时不要复用该 key 表示别的提示。
- 当前项目的手写 `.qrc` 是既有技术债；本计划只做最小登记并依赖 manifest 守门，不应借机迁移全树。
