# 项目协作规则

## 回复语言

- 与用户交流时必须使用中文。
- 解释问题、总结改动、给出命令和风险说明时，也使用中文。

## 代码注释规则

- 写代码或修改代码时，必须为非显然逻辑添加必要的中文注释。
- 注释解释“为什么这样做”和“边界条件是什么”，不要逐行翻译代码。
- 注释需要保证初学者能看懂：少用缩写和黑话；必须出现专业名词时，要用一句话说明它在当前代码里的作用。
- 优先注释以下内容：
  - 数据库迁移、事务、兼容旧数据的逻辑。
  - 跨层调用、QML 与 C++ 服务交互、信号传播。
  - 时间、日期、统计、导出、动画状态机等容易误改的逻辑。
  - 测试中为了稳定性或隔离环境而做的特殊处理。
- 不要给简单赋值、显而易见的 UI 属性、普通 getter/setter 添加噪音注释。
- 如果已有英文注释，后续维护时应改为中文，除非它是库名、协议名、宏名或标准格式标记。

## 分阶段处理规则

- 遇到大任务时，必须先拆成多个小步骤，再按阶段执行。
- 执行顺序固定为：
  1. 先创建文件框架，只包含主要结构和导入语句。
  2. 添加第一个功能模块。
  3. 添加第二个功能模块。
  4. 继续逐步补充剩余模块。
  5. 最后统一检查导入、调用关系和格式。
- 每个阶段只处理当前阶段的目标，不提前混入后续模块。
- 阶段之间要检查当前代码是否能被理解和继续扩展，发现结构问题先修正再继续。

## 代码质量规则

- 保持当前项目分层：`src/services`、`src/models`、`src/mcp`、`src/platform/macos`、`src/platform/ios`、`src/platform/apple`、`qml`、`tests` 的职责不要混杂。
- iOS 专属代码（系统框架调用、生命周期、打包配置）放 `src/platform/ios`；macOS 与 iOS 共用、接口相同的 Apple 框架实现（目前是系统通知后端）放 `src/platform/apple`，不从另一个平台的目录里借用源码；菜单栏、全局热键、外部 AI 接入这些只在 macOS 存在的能力，优先由 `CMakeLists.txt` 按平台排除源码，业务服务里尽量不新增平台判断（`PhaseSoundService` 的提示音分支是既有例外）。
- 外部 AI 接入的辅助程序（`src/mcp/helper`）只做协议与转发，不得链接业务服务、SQL 或 QML；权限判断与读写都在主应用内完成，`McpHelperLinkGate` 会检查链接结果。
- 修改功能后要运行相关构建和测试，再报告结果。
- 后台测试和自动验证不得弹出应用窗口；Qt/QML 测试默认使用 `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic`。不要在自动流程里执行 `open /Applications/番茄Todo.app`、`open build/*.app` 或其他会拉起 GUI 窗口的命令，除非用户本轮明确要求做人工真机视觉验收。
- 不要改动 `build/` 生成物。

## 构建与部署规则

- 用户说“构建”“重新构建”或要求生成最新应用时，默认含部署步骤，不能只生成临时目录中的 `.app`。
- 应用构建必须以 CMake 的 `deploy-local-app` 目标结束，将当前分支的最新应用部署到 `/Applications/番茄Todo.app`。
- 部署实现在 `cmake/DeployLocalApp.cmake`，顺序固定为：复制到 `<目标>.staging-<token>` → 校验新包主二进制存在 → 把旧包 rename 成 `<目标>.previous-<token>` → 原子 rename 换上新包 → 删除备份并 `lsregister` 刷新系统索引。任一步失败都会把旧包放回原位。**禁止改回“先删旧包再复制新包”的顺序**：那样中途失败会让用户既没有旧包也没有新包。
- 构建目录放在仓库外，禁止修改仓库内 `build/` 生成物。**不要放在 `/tmp` 下**：
  macOS 的 `/tmp` 是指向 `/private/tmp` 的符号链接，moc 生成的相对包含
  （`../../../../Users/...`）按真实路径解析会落到不存在的 `/private/Users/...`。
  Qt 6.9 之前能编过纯属偶然（它的 moc 调用带 `-I/usr/local/include`，那条搜索路径
  拼上同一串相对路径恰好回到 `/Users/...`）；Qt 6.10 换了 include 标志集之后整个
  构建直接失败。用 `~/pt-*` 这类没有符号链接的路径。
- `POMODORO_TODO_DEPLOY_LOCAL` 是 CMake cache 变量，会持久化在构建目录里。审计/测试构建传 `=OFF` 时必须用**独立的构建目录**（约定：部署 `~/pt-build`，审计 `~/pt-audit`），否则后续部署构建会因为残留的 `OFF` 而静默不部署。
- **Mac 构建目录只允许这两个**：`~/pt-build`（部署）与 `~/pt-audit`（验证）。不要按用途另建
  `pt-warn3`、`pt-gate`、`pt-c1` 这类一次性目录——它们每个 300–450M，只增不减，
  一次就攒到过 3.3G。此前放在 `/tmp` 时系统重启还能捡回来一点，改到 `~` 之后
  再也没有任何自动清理，只能靠人记得。
  临时验证就在这两个里跑；确实需要隔离的（比如换 Qt 版本、开消毒器），
  **用完当场 `rm -rf`，不留到下一轮**。
- iOS 构建只用 `~/pt-ios`，这个目录**永不部署**，也不接 `deploy-local-app`。命令（均先
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 指定 Xcode，不依赖 `xcode-select` 的全局设置）：
  - 配置：`~/Qt/6.10.3/ios/bin/qt-cmake -S <源码目录> -B ~/pt-ios -G Xcode -DQT_HOST_PATH=$HOME/Qt/6.10.3/macos`
    （iOS 套件是交叉编译的，必须用 `QT_HOST_PATH` 指向本机的 macOS 版 Qt，否则配置阶段就失败）；
  - 自动流程只做不签名的编译检查：`cmake --build ~/pt-ios --config Debug -- -sdk iphoneos CODE_SIGNING_ALLOWED=NO`；
  - 签名编译必须直接用 `xcodebuild` 并带 `-scheme`：`xcodebuild -project ~/pt-ios/PomodoroTodo.xcodeproj -scheme PomodoroTodo
    -configuration Debug -destination id=<设备 UDID> -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`。
    `cmake --build` 不传 scheme，xcodebuild 会忽略目标设备，免费个人团队就登记不上设备、生成不了描述文件。
    开发团队 ID 用缓存变量 `POMODORO_TODO_IOS_DEVELOPMENT_TEAM` 传入（`defaults read com.apple.dt.Xcode | grep teamID` 可查）。
  - 设备 UDID 用 `xcrun devicectl list devices` 查；安装 `xcrun devicectl device install app --device <UDID> <.app 路径>`，
    启动并接收日志 `xcrun devicectl device process launch --device <UDID> --console --terminate-existing <包标识>`，
    截图 `xcrun devicectl device capture screenshot`，取回沙盒文件 `xcrun devicectl device copy from --domain-type appDataContainer`。
- 往真机安装、启动应用，**必须用户本轮明确同意**；否则自动流程只编译 `~/pt-ios`。任何情况下都不启动模拟器。
  第一次安装免费团队签名的应用后，要由用户在设备的"设置 → 通用 → VPN 与设备管理"里信任开发者，应用才能启动。
- 部署完成后必须校验构建包与 `/Applications/番茄Todo.app` 主二进制一致，并报告部署结果。
- 构建和部署不等于启动。未经用户本轮明确要求，禁止执行 `open`、直接运行应用二进制或以其他方式拉起 GUI。
- 如果部署时已有番茄 Todo 进程运行，不得擅自结束进程；需要明确提醒用户退出并重新打开，才能加载新二进制。

## Qt/QML 界面规则

- 创建、修改或重构 Qt 6/QML 界面时，必须使用 `qt-qml` 和 `qt-ui-design` Skill，并遵守项目现有 `Theme.qml`、Qt Quick Controls 风格、组件边界和交互模式。
- 涉及毛玻璃、液态玻璃、折射或背景采样时，必须参考 `liquid-glass` Skill 的光学分层、边缘折射、背景采样和高光设计；该 Skill 的 Web 实现只作为原理参考，不能复制其技术栈。
- 界面实现只允许使用 Qt 6、QML 和项目现有 C++ 后端。禁止生成或引入 SwiftUI、UIKit、CSS、HTML、JavaScript Web UI、React 或其他 Web 前端实现。
- 优先使用 QML `Rectangle`、`MultiEffect`、`ShaderEffect`、`layer.enabled`、`Behavior`、`NumberAnimation` 和 Qt Quick Controls。Shader 必须采用 Qt 6 支持的预编译资源形式，并提供资源测试。
- 毛玻璃只用于导航栏、浮动工具栏、弹窗和重要控制组件。普通任务卡、统计卡及主要内容区域必须保持清晰，禁止把所有卡片都做成实时玻璃。
- 光学层按“背景采样/折射 → 半透明着色 → 边缘高光 → 业务内容”组织；业务内容始终位于最高层，不能被 Shader 或模糊层直接处理。
- 浅色和深色背景必须同时保证文字、图标、输入边界和焦点状态的对比度。颜色优先使用 `Theme.qml` 的语义令牌，禁止依赖单一颜色表达状态。
- 以稳定 60 FPS 为优先目标。限制实时模糊与 Shader pass 数量，静态背景采样应按需更新；页面不可见或效果关闭时必须停止更新或卸载效果层。
- 必须提供不支持模糊、关闭模糊、缺少采样源或 Shader 初始化失败时的半透明纯色降级方案。降级后业务功能、布局和文字可读性不能受损。
- 动效必须支持 `reduceMotion`，并保证鼠标、键盘焦点和屏幕阅读器基础可用性。

## Git 提交规则

- Git 提交说明必须使用中文，清楚描述本次提交解决的问题或完成的功能。
- **每次把分支合并回 `main` 之前，必须先删除这个分支工作中产生的全部副产物文档，再合并。**
  - 副产物指只为开发过程服务、不作为交付物保留的文件：截图与渲染图（png、jpg 等）、HTML 预览与设计稿、
    头脑风暴与可视化产物（`.superpowers/`、`.codex/visualizations/` 等）、日志、临时计划与审查记录、临时备份文件。
    仓库内外都算：为这个分支的工作写到仓库外的截图、日志同样要删。
  - 已提交到分支的副产物用 `git rm` 删除，随分支一起合并，保证合并后 `main` 上不留；
    没进 git 的（未跟踪或被 `.gitignore` 忽略）直接从工作区删掉。
  - 计划文件沿用现有留档约定：正文先随功能提交入库，删除后在 `plans/README.md` 用
    `git show <提交>:<路径>` 指回留档提交，不能跳过入库直接删。
  - 不是副产物、不得删除：源码、测试、`docs/` 下的正式文档、`plans/README.md` 索引、
    `~/pt-build`、`~/pt-audit`、`~/pt-ios` 构建目录、仓库内 `build/` 生成物（本来就禁止改动）、
    `.cache/` 语言服务器索引、`tests/mcp-sdk/node_modules/` 测试依赖、个人本地配置。
  - 删除前先列出清单核对。不是本分支产生的旧遗留，列出来询问用户，不擅自删除。

## Qt Skill 维护规则

- `.agents/skills/` 中的七个 Qt skill 由本项目维护；构建、部署、无显示验证、目录分层等项目事实只在本文件维护，skill 不复制另一套配置。
- 普通 QML 修改使用编码与界面规则；完整 review 仅在用户明确要求审查时触发，profiler 仅用于性能调查。按实际改动选择检查范围，不固定启动多个代理。
- Qt Quick Test 的编写、执行和诊断统一使用 `qt-qml-test`，原 `qt-qml-test-run` 已合并。
- 文档与 Figma 四个低频 skill 位于 `.agents/skills-archive/`，不在普通任务中读取；需要恢复时按该目录说明操作。
- Qt skill 的原始来源及哈希保存在 `.agents/skills-archive/upstream-lock.json`，本地定制不再列入根目录 `skills-lock.json` 的上游安装集合。更新时人工核对差异，避免覆盖项目规则。
