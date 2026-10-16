# 061：SQLite运行时同源与事务锁保护

状态：用户批准后已按顺序完成实现及本地验收。旧实现4项锁断言失败、4项同实例对照通过；同源驱动接入后全部通过，误载旧插件及包内遗漏反证有效。最终Mac构建、CTest134/134（47.31秒）、Swift395/395、SDK58次调用和iOS不签名编译通过，尚未提交／推送。详见[061验收报告](../docs/061-SQLite同源与写锁保护验收报告.md)。

## 基线、问题与验收目标

- 计划基线：2026-10-16，分支`fix/058-audit-gates`，HEAD=`d8e6c525`。059、重入补修和060仍在未提交工作区；HEAD本身不含这些实现。开工前以`.superpowers/060/accepted-source-sha.json`核对产品源码，另外保留当前`git diff`与未跟踪文件清单。本计划和计划索引属于后续有意更新，不要求它们继续匹配旧文档摘要。
- 优先级：P1；工作量：M；修复风险：高。依赖059的独立连接、协作取消和恢复保护，以及060的关闭记录保护。
- 当前Mac主库的Qt插件内嵌SQLite 3.51.3，备份驱动链接系统SQLite 3.54.0。两套运行实例各自管理文件锁，关闭备份连接会解除主连接仍依赖的进程级锁。
- 已复现：Qt主连接`BEGIN IMMEDIATE`后执行未提交写入，外部独立进程最初得到`SQLITE_BUSY`；另一份SQLite执行`VACUUM INTO`并关闭连接后，外部进程得到`SQLITE_OK`。DELETE、WAL均如此。同一份Qt SQLite的对照组关闭前后均为`SQLITE_BUSY`。
- 证据：`.superpowers/submit-review-20261016/sqlite-lock-probe.json`、`sqlite-snapshot-lock-control.json`。只证明锁不变量失效，未制造真实数据损坏；探针二进制和对象已删除。

目标是：**同一进程内并发访问主库的连接共用一个SQLite运行实例；备份连接独立持有，SQL协作取消继续有效。** 同版本号不等于同一运行实例，最终以链接来源和事务锁回归共同证明。

## 推荐实现

### Mac：项目内构建应用专用QSQLITE插件

使用与SDK完全匹配的Qt 6.10.3官方SQL驱动源码，单独构建链接系统`SQLite::SQLite3`的QSQLITE插件，使Qt主连接、同步／导出连接和BackupSqliteDriver调用同一份系统SQLite。插件只输出到`~/pt-audit`或`~/pt-build`的生成目录及应用包，不覆盖`~/Qt`中的原插件。

Qt官方允许在二进制SDK上单独构建SQL驱动，要求源码与SDK版本一致：

- [Qt 6.10 SQL驱动独立构建](https://doc.qt.io/qt-6.10/sql-driver.html#compile-only-a-specific-sql-driver)
- [6.10.3驱动配置](https://github.com/qt/qtbase/blob/v6.10.3/src/plugins/sqldrivers/configure.cmake)：`system-sqlite`特性默认不自动开启，必须显式要求。
- [6.10.3 QSQLITE构建定义](https://github.com/qt/qtbase/blob/v6.10.3/src/plugins/sqldrivers/sqlite/CMakeLists.txt)：该特性开启时链接`SQLite::SQLite3`，关闭时编译内嵌`sqlite3.c`。

官方源码包：`https://download.qt.io/official_releases/qt/6.10/6.10.3/submodules/qtbase-everywhere-src-6.10.3.tar.xz`。
SHA-256：`383dc907816338f0cba72088a524c07458dfc69ce684ca9132fcc4fe91c24b0b`，来源为官方同名`.sha256`文件。执行前重新核对；不匹配就停止，不自行改成新摘要。保留源码原许可证和来源记录，不提交下载缓存或预编译插件。

构建必须可在GitHub runner重现，不能依赖本机手动替换过的SDK。优先封装到项目CMake辅助文件，由原有构建目录生成插件；只构建QSQLITE，不引入其他数据库客户端依赖。检查官方构建辅助逻辑对Mac架构的处理，产物必须含当前应用需要的arm64。本机SDK的`QtTargetHelpers.cmake:1481`已确认：通用Mac构建在系统库场景可能把插件压到x86_64；它识别`QT_FORCE_MACOS_ALL_ARCHES_QSQLiteDriverPlugin`覆盖项。阶段验证应显式指定目标架构，并结合该覆盖项阻止意外降为Intel，通过`lipo -archs`验证实际产物，不更改SDK脚本。若仍不能满足arm64，停止并报告，不生成仅x86_64的替代品。

运行时必须明确加载项目生成／随应用打包的插件，并在首个数据库连接创建前注册QSQLITE工厂。可使用`QPluginLoader`与`QSqlDatabase::registerSqlDriver()`的公开接口；注册工厂须持有插件加载器的生命周期，任何连接仍存活时都不能卸载插件。不能只追加搜索路径后假定Qt一定选中新插件。目标插件缺失或加载失败时，沿用现有启动失败路径报告并退出，不静默回退到SDK内嵌SQLite插件。

### iOS：保留当前静态链接，补证而不盲目重构

059的二进制核对显示，备份适配器使用的27个API在iOS最终可执行文件内均解析到静态SQLite定义。继续核对Qt主驱动的实际引用也指向同一套定义；不能仅凭“均为静态符号”或版本相同就得出结论。

若确实同源，保留当前路径，不添加Mac动态插件装配。若发现第二套访问主库的SQLite实例，停止并单独制定iOS修正，不把Mac方案机械移植到iOS。设备运行仍未验，静态链接与不签名编译不得写成真机通过。

## 当前关键实现与边界

以下源码摘录用于漂移检查，实施前必须自己打开文件核对：

```cpp
// src/services/DatabaseManager.cpp：主库仍通过Qt驱动工厂创建。
m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connectionName);

// src/services/BackupOperations.cpp：另一份运行时打开同一路径，随后关闭。
QSqlDatabase source = QSqlDatabase::addDatabase(new BackupSqliteDriver(control), connectionName);
source.setDatabaseName(sourceDatabasePath);
// ... PRAGMA user_version、VACUUM main INTO ...
source.close();

// src/services/BackupSqliteDriver.cpp：自建连接，不借用Qt连接句柄。
sqlite3_open_v2(path.toUtf8().constData(), &m_database, flags | SQLITE_OPEN_NOMUTEX, nullptr);
sqlite3_close_v2(m_database);
```

不使用系统API操作SDK内嵌SQLite创建的句柄；现有Mac插件没有导出可复用的`sqlite3_*`接口，不使用`dlsym`猜测私有符号。也不把当前窄范围BackupSqliteDriver扩成全项目通用SQL驱动，以免引入`lastInsertId`、类型、游标等兼容缺口。

目录和依赖遵守AGENTS：平台装配放`src/platform/macos`及Mac入口，服务层不加平台宏；PTCore、PTApp不链接QML。新插件的Qt私有依赖局限于独立驱动构建，不加入PTCore白名单。测试若直接编译DatabaseManager而不链接PTCore，也必须得到同样的Mac驱动装配，不能只修主应用。

## 允许改动范围

- `CMakeLists.txt`：插件生成、依赖、Mac应用打包及测试装配；按实际所属目标登记新增文件。
- `cmake/QtSqliteRuntime.cmake`（新建）：固定源码获取／校验、插件构建和产物路径；必要时增加一个同目录校验脚本，职责仅限本项。
- `src/platform/macos/SqliteRuntime.h`、`.cpp`（新建）：确定性加载与注册，以及错误传播；不持有业务状态。
- `src/entry/mac/main.cpp`：在第一项数据库操作前装配；沿用现有失败出口。
- `tests/SqliteRuntimeTests.cpp`（新建）：运行时来源、锁不变量、加载失败、生命周期回归。
- `tests/SqliteRuntimeTestBootstrap.cpp`（如需要新增）：Mac测试统一装配，覆盖直接编译服务的测试目标。
- `tests/BackupServiceTests.cpp`：恢复正式锁回归及取消／真实备份组合验证；复用现有临时数据库、QProcess和作用域清理模式。
- `.github/workflows/verify.yml`：仅在独立构建需要显式准备固定源码时调整；保留完整原始MCP压力及全部现有门禁。
- `docs/运行命令.md`、`docs/业务规则.md`、059验收报告、审计总表，以及058／059／061计划和`plans/README.md`：实施后同步真实状态和边界；历史证据保留，不追改旧失败为成功。

若需要修改BackupSqliteDriver／BackupOperations的产品逻辑、iOS装配或架构门禁白名单，先报告所需变化及原因，再调整计划；不要自行扩大为主库驱动重写。

## 执行步骤

1. **固定起点。** 保存当前源码摘要、工作区文件清单，确认059与060仍完整；确认两个cache指向本仓库且部署OFF。构建目录里不放源码、计划或日志。
2. **先补产品回归并取得红灯。** 在正式测试中保持主连接未提交写事务，以独立进程探测写锁，覆盖读取关闭与实际`VACUUM INTO`关闭两个截面、DELETE／WAL两种模式。动作前断言外部写入被拒绝，动作后要求仍被拒绝；现实现应在后一断言失败。同实例对照组应通过。测试清理必须先结束查询／事务，再关闭连接和临时目录，避免自己解除锁或污染后续用例。父进程设置有限护栏，不用固定睡眠猜测阶段。
3. **完成同源插件可行性。** 在现有Mac构建目录内生成固定版本插件，不安装进SDK。确认arm64、对系统SQLite的依赖、测试进程实际加载路径；使用当前产品备份驱动重跑锁探针。此阶段成功前不改业务装配；失败按停止条件报告。
4. **接入应用与全部SQL测试。** 复用同一个加载／注册实现；主应用和测试必须在任何QSQLITE连接出现前完成。明确区分生成路径和应用包内路径；插件加载失败必须阻断，不能回退。所有QSQLITE调用继续得到官方Qt驱动的完整语义。
5. **证明取消能力与兼容没有退化。** 重跑长SQL进度取消、锁等待取消、复制提交前／后、安装取消回滚、超预算回滚、退出／重启保护、059重入及060关闭意图回归；真实Qt6.9完整备份夹具继续通过。增加主事务／快照重叠期间的锁保护验证，不用单一版本号断言代替。
6. **增加构建和运行门禁。** 插件来源与依赖、应用包包含指定插件、加载失败拒绝回退均有自动检查。核实iOS主驱动与C API同源，并记录最终二进制证据。移除插件或使测试误载SDK原插件时，新增门禁必须失败，随后按原字节还原。
7. **全量验收与文档。** Mac完整构建／全量CTest、独立Swift、iOS不签名编译、SDK验证；确认无新增编译告警。更新当前状态及本次锁补修证据，不把059永久I/O边界、设备验收和原审计其他问题写成完成。

## 验证命令与结果要求

命令从仓库根执行；首次重新配置前按AGENTS列出构建目录顶层，存在非构建文件时停止询问，不删除或覆盖它们。普通构建不得使用会部署的`~/pt-build`。

| 目的 | 命令 | 通过要求 |
|---|---|---|
| 工作区 | `git status --short --branch`、`git rev-parse HEAD` | 基线、既有改动与本项增量均可区分 |
| 构建来源 | `rg 'CMAKE_HOME_DIRECTORY|POMODORO_TODO_DEPLOY_LOCAL:' ~/pt-audit/CMakeCache.txt ~/pt-ios/CMakeCache.txt` | 源码为本仓库，部署均OFF |
| Mac构建 | `cmake --build ~/pt-audit -j8` | 插件与应用／测试均成功，无新增告警 |
| 锁及取消专项 | `ctest --test-dir ~/pt-audit -R '^(SqliteRuntimeTests|BackupServiceTests|SyncControllerTests|SharedAppTests)$' --output-on-failure --timeout 240` | 所有目标通过；新目标不能零用例 |
| 全量 | `ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8` | 全部通过，总目标数按新增测试据实记录，不硬套旧133 |
| iOS | `cmake --build ~/pt-ios --config Debug -- -sdk iphoneos CODE_SIGNING_ALLOWED=NO` | 成功，无新增编译／链接告警；已有工具诊断单列 |
| Swift | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path src/ui/ipad --scratch-path ~/pt-audit/ipad-swift` | 395项既有用例继续通过；新增时按实际数量记录 |
| SDK | `npm test --prefix tests/mcp-sdk` | 两个协议版本58次调用继续通过 |
| 差异 | `git diff --check` | 通过，受控变异全部还原 |

直接运行测试二进制时设置`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic`。复用现有CTest入口环境；有无关失败则单独重跑一次并保留失败记录，不顺手修其他功能。

## 完成标准

- [x] 新锁用例在当前产品实现得到有效断言红灯，同实例对照通过。
- [x] 修复后DELETE与WAL中，主事务未结束前，快照连接读取／关闭和实际VACUUM／关闭均不能让外部进程取得写锁。
- [x] Mac主驱动与备份C API实际调用同一SQLite运行实例；插件arm64与系统库依赖验证通过。
- [x] 主应用、所有直接／间接SQL测试明确使用同一套装配；插件缺失时失败，不回退旧插件。
- [x] 独立连接、长SQL与等锁协作取消、提交事实、回滚安全、重入和060跨进程保护均保留。
- [x] iOS链接来源复核、不签名编译、Mac构建、全量CTest、Swift与SDK全部通过，无新增编译告警。
- [x] 当前状态文档明确本项完成证据及既有边界，未把全仓整改写成全部完成。
- [x] SDK及已安装应用未被修改，临时探针产物已删除；本轮不自动提交、推送、合并或部署。

## 停止条件与维护

- 固定Qt源码不匹配、插件无法满足arm64或依赖当前SDK没有的私有接口时停止，不升级Qt来绕过。
- 插件加载依赖修改全局SDK、不能可靠阻止旧插件回退，或需要额外应用子进程时停止并提交方案差异。
- iOS并非同源、修改涉及schema／同步格式／备份格式时停止，不沿用本计划授权扩大范围。
- Qt升级必须同步更新固定驱动源码、来源摘要及ABI检查，并重跑锁不变量；系统SQLite版本更新后也继续跑同一门禁。
- 120秒仍只是协作预算；本项不承诺永久系统I/O或整个进程退出硬期限，不启动应用、模拟器或真机。

## 最终实施记录

采用独立MODULE目标编译固定归档中的官方适配源码，链接SDK导出的PlatformPluginInternal配置和系统SQLite，未走Qt内部会降级Intel的整套驱动构建，也未修改官方源文件或SDK。构建源码位于忽略缓存，只有产物位于指定构建目录。35个SQL可执行目标实际装配检查通过；主应用包内插件逐字节核对通过，许可证与来源记录随包生成。iOS备份27个API唯一静态定义，Qt主驱动与备份open方法均调用同一个sqlite3_open_v2地址；设备执行仍未验。

有效反证：旧实现正式回归4红／4对照绿，误载SDK插件4项重现红灯，临时遗漏包内插件1项红灯；全部还原后完整回归134/134。测试、源码及包内文件未在全量验收期间继续变异。原059永久I/O与退出硬期限、设备实测、原审计其余问题均未扩大关闭。
