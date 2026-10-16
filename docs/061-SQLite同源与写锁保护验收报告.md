# 061：SQLite同源与写锁保护验收报告

> 2026-10-17 交付更新：059／060／061 已随 `00014ef` 提交并推送，远端 CI 第 2 次运行通过。最新交付与设备边界见[交付清单](058-061-交付与设备验收清单.md)。下文未提交、未推送及旧 HEAD 等表述属于当时的阶段记录；本地开发日志按合并流程清理，正式结论及远端证据保留。

日期：2026-10-16。计划：[061](https://github.com/litoseason86-lab/-todeQt-c-/blob/00014ef7d4497d61142e2c045cb304c822487e68/plans/061-SQLite运行时同源与事务锁保护.md)。对象：`fix/058-audit-gates`未提交工作区，HEAD仍为`d8e6c525`，不含059／060／061。最终文件摘要保存于被忽略的`.superpowers/061/accepted-source-sha.json`。

## 结论与实现

059新增双SQLite运行实例导致Mac写锁失效的问题已修复，并完成正式回归、错误插件变异、包内遗漏反证及完整本地验收。Mac主库、同步／导出Qt连接与备份C API共用系统SQLite；独立连接、协作取消、恢复保护和060关闭意图保留。未改变schema、同步协议或备份格式。

- `cmake/QtSqliteRuntime.cmake`固定Qt 6.10.3官方源码包及SHA-256，仅编译驱动适配源码，不编入`sqlite3.c`。独立MODULE链接系统SQLite并继承应用arm64架构，SDK原插件不修改。官方源码不打补丁，使用SDK导出的`Qt6::PlatformPluginInternal`编译配置；首次缺失该配置的编译错误已保留日志，不计作产品红灯。
- `MacSqliteRuntime`明确加载指定插件，通过公开`registerSqlDriver()`注册工厂并持有加载器；不依赖插件搜索顺序。Mac入口在第一项数据库操作前装配，缺失／损坏时走既有启动失败出口，不回退SDK内嵌驱动。
- 实际链接清单检查35个SQL可执行目标：33个经公共测试启动装配，主应用与运行时测试显式装配，无遗漏。MCP纯协议helper未增加SQL依赖，架构与链接门禁通过。
- 独立打包目标在插件单独重编后也同步应用副本；包内包含许可证、来源URL和归档摘要，测试核对插件SHA一致。源码缓存与构建日志分别保留在仓库忽略目录`.cache/`和`.superpowers/061/`。

## 修复前后及反证

`BackupServiceTests::backupConnectionClosePreservesMainWriteLock`有8行数据：DELETE／WAL、读取关闭／VACUUM关闭、备份驱动／同实例对照。主连接先开启未提交写事务，独立进程在动作前必须得到`SQLITE_BUSY`；快照读取或生成成功并关闭后，外部写事务仍须被拒绝，主连接未提交值保持不变。探针取得锁后只回滚，不修改数据。

| 证据 | 结果 |
|---|---|
| 旧实现＋新正式回归 | 4项备份驱动断言失败，4项同实例对照通过；6 passed／4 failed包含初始化与清理 |
| 同源插件接入后 | 8行锁场景全部通过；真实加载路径见`pilot-lock-tests.log` |
| 临时把公共启动装配指向旧SDK插件 | 构建成功后4项锁断言重新失败；源码按原字节还原、重建后全绿 |
| 临时移走审计应用包内插件 | `applicationContainsVerifiedPlugin`断言失败；已恢复原文件，未操作安装目录 |
| 独立进程加载失败 | 缺失、损坏、装配过晚均返回错误且未安装工厂，不借已存在注册表得到假绿灯 |

变异、还原和最终验收串行执行。红灯均为明确产品断言，不是编译失败或测试超时。只证明并修复锁不变量失效，没有制造或声称发生实际用户数据损坏。

`SqliteRuntimeTests`最终9/9（含初始化／清理）覆盖插件系统库依赖、无内嵌open／step定义、CPU架构、包内SHA、实际引擎版本、插入编号、中文及含NUL文本／BLOB字节、重复装配与三类失败。既有长SQL／等锁取消、复制提交边界、安装取消回滚、独立回滚预算、退出／重启、059重入、060跨进程保护及Qt6.9完整备份夹具继续通过。

## iOS来源证据

iOS保留原静态链接：备份适配器27个API均只有一个静态代码定义；进一步反汇编Qt主驱动与备份驱动的open方法，两者均直接调用`0x100a91314 <_sqlite3_open_v2>`。这补齐此前只看适配器API、没有核对主驱动实际引用的遗漏。地址和最终二进制SHA保存于`ios-driver-calls.json`、`ios-sqlite-provenance.json`，不要求其他构建沿用此地址。未做真机执行。

## 本轮实际命令与结果

| 命令／检查 | 结果 | 证据（`.superpowers/061/`） |
|---|---|---|
| `cmake --build ~/pt-audit -j8` | 成功，无新增编译告警 | `accepted-mac-build.log` |
| `ctest --test-dir ~/pt-audit --output-on-failure --timeout 240 -j8` | 134/134，47.31秒 | `accepted-ctest.log` |
| 同次备份／同步控制器／共享装配／运行时 | 137/137、76/76、18/18、9/9 | 同次LastTest结果摘要 |
| `cmake --build ~/pt-ios --config Debug -- -sdk iphoneos CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED，无新增编译／链接告警 | `accepted-ios-build.log` |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path src/ui/ipad --scratch-path ~/pt-audit/ipad-swift` | 395/395，0失败 | `accepted-swift.log` |
| `npm test --prefix tests/mcp-sdk` | 两个协议版本58次调用通过 | `accepted-sdk.log` |
| SQL目标实际装配 | 35/35，无遗漏 | `sql-target-wiring.json` |
| `git diff --check` | 通过，变异均还原 | 最终文件摘要及差异核对 |

两个cache均指向本仓库、部署OFF。`pt-audit`既存`ios-build.log`经用户许可归档后才重新配置。iOS保留已有CoreSimulator版本落后诊断及AppIntents元数据跳过提示，均不是本次新增编译／链接告警；未为处理它们启动模拟器。

## 交付及保留边界

本轮本地P1阻断已关闭，可以进入按文件提交及功能分支远端CI验证阶段；尚无059／060／061工作区的远端绿灯。main保护实查要求“macOS 构建与回归”、分支最新、管理员受限、禁止强推和删除。

未提交、推送、合并、部署，未启动正式应用、模拟器或真机。总表新增A069记录本项，69个对照项不是69个独立Bug，不计算整改百分比。059永久I/O／完整退出硬期限、设备实测、用户实际历史备份及原审计其余问题继续保留。后续Qt升级须同步更新固定驱动源码与ABI门禁，并重跑锁回归。
