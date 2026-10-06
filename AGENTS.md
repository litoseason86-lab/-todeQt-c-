# 项目协作规则

本文件只放每次任务都适用的规则；其余内容按文末「按需读取」去对应文件找。

## 沟通与授权

- 回复用户、代码注释、提交说明、文档一律用中文；标识符、命令、路径、库名保持原文。
- 需求有两种以上合理理解且结果不同（数据、界面版式、同步行为）→ 先问。其余按现有代码惯例自己决定，不反复确认。
- 以下动作只在用户本轮明确要求时做：
  - 启动应用：`open`、直接运行应用二进制、任何会弹出窗口的命令；
  - 往真机签名、安装或启动应用（任何情况下都不启动模拟器）；
  - 合并回 `main`、推送到远端。
- 不可回退的改动（数据库 schema 升版本、同步批次格式升版本、删除用户数据）→ 先写明影响，得到用户同意再做。
- 界面大改（新页面、改版式）→ 先出设计稿给用户确认；设计稿形式不限，按副产物处理。

## 改动边界

- 只改完成任务需要的代码。顺手发现的问题写进汇报，不顺手修、不顺手重构。
- 工作区里与本任务无关的未提交修改：不覆盖、不还原、不一起提交；提交时按文件添加，不用 `git add -A`、`git commit -a`。
- 新增 C++/Objective-C++ 源文件登记到 `CMakeLists.txt` 对应的源文件列表；新增 `qml/` 下的文件登记到 `resources/qml.qrc`（`tests/qml/tst_*.qml` 自动收集，不用登记）。
- 临时文件（截图、日志、试验脚本）写到仓库外的，本次任务结束前删掉；要跨会话保留的，放仓库内已被忽略的目录（如 `.superpowers/`）。
- 仓库内 `build/` 是旧产物：不写、不删、不当构建目录。
- 目录职责：
  - `src/services`：平台无关的业务逻辑。不写平台分支（`Q_OS_*`、`#ifdef`），现存例外只有 `PhaseSoundService` 的提示音。
  - 需要平台差异 → 在 `src/platform/macos` 或 `src/platform/ios` 写后端，服务经接口调用（照 `NotificationService` + `NotificationBackend`）。两个平台接口相同的 Apple 框架实现放 `src/platform/apple`；不从另一个平台的目录借源码。
  - 只在 macOS 存在的功能（菜单栏、全局热键、外部 AI 接入）由 `CMakeLists.txt` 按平台排除源码。
  - `src/mcp/helper` 只做协议转发，不链接业务服务、SQL、QML（`McpHelperLinkGate` 测试会拦）；权限判断和读写在主应用内完成。

## 编写约定

- 必须写注释：数据库迁移、事务、兼容旧数据；QML 与 C++ 的跨层调用和信号传播；时间、日期、统计、导出、动画状态机；绕开 Qt 或平台缺陷的代码（写明现象和版本，只写实测或文档确认过的行为）；测试里为稳定或隔离做的特殊处理。
- 注释写为什么和边界条件，不逐行翻译代码；简单赋值、普通 UI 属性、getter/setter 不加注释。注释里第一次出现的专业名词附半句说明它在这里的作用，同一文件不重复解释。
- 改 `qml/` 的布局、交互或视觉前，先读 `.agents/skills/qt-qml/SKILL.md`、`.agents/skills/qt-ui-design/SKILL.md` 和 `docs/业务规则.md`「界面与验证约定」。
- 应用界面只用 Qt 6 QML + C++ 后端，不写 SwiftUI、AppKit/UIKit 视图或 Web 前端。`src/platform/` 里为调用系统功能（文件夹选择、后台任务、菜单栏）使用 AppKit/UIKit 不受此限。
- 新写的界面颜色只用 `Theme.qml` 的语义令牌；新增动画响应 `Theme.reduceMotion`。

## 测试

- 每个新测试函数，注释第一句写它保证的产品行为，再据此设计数据和断言。
- 数据要让违反保证的实现得到不同结果：验证排序时插入顺序 ≠ 期望顺序；验证移到末尾时原序号 ≠ 末尾序号；验证批量回滚时先成功写入至少一条，再让后续写入失败。用例依赖的前提，在动作前先断言成立。
- 修 bug：新用例先在修复前跑一次，确认失败。给已有行为补测试：临时改坏对应实现，确认用例失败，再还原并用 `git diff` 确认已还原。

## 构建、验证与交付

- Mac 只用两个构建目录：`~/pt-build`（只配 `POMODORO_TODO_DEPLOY_LOCAL=ON`，这里的任何构建都会部署）和 `~/pt-audit`（只配 `=OFF`）；iOS 只用 `~/pt-ios`，永不部署。不建别的构建目录、不用 `/tmp`；确需隔离（换 Qt 版本、开消毒器）用 `~/pt-<用途>`，用完当场 `rm -rf`。
- 其它 worktree 里的任务也用这几个目录：构建前确认 `CMakeCache.txt` 的 `CMAKE_HOME_DIRECTORY` 指向当前源码目录，不是就先问用户；重新配置或 `rm -rf` 前，先列出目录顶层不属于构建产物的文件，有就先问。构建目录里不放非构建文件。
- 改了 C++、QML 或 CMake → 在 `~/pt-audit` 构建并跑全量 `ctest`（约 30 秒）；只改文档或注释 → 不构建。
- 测试一律离屏：`ctest` 已在 CMake 里设好环境；直接运行测试二进制时加 `QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic`；新增测试目标照现有写法设 `ENVIRONMENT`。
- 全量测试出现与本次改动无关的失败 → 单独重跑一次；仍失败就在汇报里写明，不顺手修。
- 代码改动的完成标准：构建通过、全量 `ctest` 通过、没有新增编译告警。汇报写实际运行的命令和结果，没运行的标「未运行」。
- 用户说「构建」「重新构建」或要最新应用 → 在 `~/pt-build` 构建（`deploy-local-app` 会部署到 `/Applications/番茄Todo.app`），然后：
  1. 按 `docs/运行命令.md` 用 `shasum` 校验 `PomodoroTodo`、`PomodoroTodoMcp` 两个二进制与已部署的一致；
  2. `pgrep -x PomodoroTodo` 有结果 → 不结束进程，提醒用户退出后重新打开。
- iOS 只在 `~/pt-ios` 做不签名编译检查；签名与装机命令见 `docs/运行命令.md`。

## 合并与推送

- 提交只在功能分支上做（在 `main` 上就先建分支）；提交说明写清解决的问题或完成的功能。
- 合并回 `main` 前，按 `.agents/skills/merge-to-main/SKILL.md` 清理副产物、归档计划、跑 iOS 不签名编译。
- 远端 GitHub 仓库是公开的：团队 ID、设备 UDID、证书、私钥不写进任何入库文件；推送前用 `git log -p origin/main..HEAD` 检查全部待推内容。

## 按需读取

| 情况 | 先读 |
| --- | --- |
| 构建、部署、iOS 签名与装机、排错 | `docs/运行命令.md` |
| 改某个功能的业务行为 | `docs/业务规则.md` 对应章节 |
| 改数据库结构、备份恢复、设备同步、外部 AI 接入 | `docs/业务规则.md`「数据安全与跨层交互」「设备间同步」「外部 AI 接入」 |
| 写或跑 Qt Quick Test、做变异验证 | `.agents/skills/qt-qml-test/SKILL.md`；本项目的坑见同目录 `references/project-pitfalls.md` |
| 写计划 | `plans/README.md`；文件名 `plans/<三位编号>-<标题>.md`，开工时登记到「进行中的计划」 |
| 用户要求审查 / 调查性能 | `qt-qml-review`、`qt-cpp-review` / `qt-qml-profiler`（只在这两种情况下用） |
| 修改 `.agents/skills/` | `.agents/skills-archive/README.md` |

同名技能以 `.agents/skills/` 下的项目版为准，不用 `qt-development-skills:` 前缀的插件版。
