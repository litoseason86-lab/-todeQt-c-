# 备份兼容样本

`backup-settings-scalars.json`是按QVariant标量的大端格式独立构造的合成字节样本，不能称为用户历史备份。

`backup-qt690-cc58394.tomatobackup`由真实Qt6.9.0 SDK和提交`cc58394f1e6c482c65a484b091eef86fa055f234`的原始BackupService/BackupOperations生成。内容仅包含一条虚构任务、一条1500秒专注和五项虚构偏好；没有读取用户正式数据库或偏好。生成时间为2026-10-16，因此它是“旧SDK/旧实现的新生成兼容样本”，不是用户在旧版本使用期间留下的历史文件。

完整性、源码版本和SHA记录在相邻provenance.json。当前BackupServiceTests在同步、异步两种入口实际恢复该文件，验证替换不同的当前任务/偏好，并保留标题、时长及整数/浮点/布尔/Unicode值。

## 再生成

需要本机有Qt6.9.0 SDK。按AGENTS更换SDK的隔离例外使用`~/pt-qt69-compat`，部署OFF，完成后当场删除，不复用正式审计或部署目录。

1. 把上述提交用`git archive`展开至隔离源码目录，保持生产源码不变。
2. 用`patch -p1`应用相邻`backup-qt690-generator.patch`；此补丁仅增加测试生成器和临时INI/测试身份隔离。
3. 用Qt6.9.0的`qt-cmake`配置隔离目录，明确`POMODORO_TODO_DEPLOY_LOCAL=OFF`；只构建`BackupServiceTests`。
4. 设置`QT_QPA_PLATFORM=offscreen`、`QT_QUICK_CONTROLS_STYLE=Basic`，把`POMODORO_QT69_FIXTURE_OUTPUT`指向新的隔离输出文件，运行`BackupServiceTests generateQt69CompatibilityFixture`。生成器会断言实际qVersion为6.9.0且拒绝覆盖已有输出，不启动应用窗口。
5. 用只读SQLite核对integrity_check、schema21、format1、任务/专注条数及backup_settings键，重新记录二进制SHA和生产源码SHA。随机同步身份及创建时间可能导致不同运行的完整文件SHA不同，不能要求重新生成结果逐字节相同。
6. 在当前SDK跑兼容回归，完成后移除隔离构建和源码副本。若要更新入库样本，需重新核对虚构数据和provenance，不得替换成用户正式备份。

该夹具不能证明所有历史schema、损坏备份或用户数据均已兼容，也不代替真实iCloud/设备验收。
