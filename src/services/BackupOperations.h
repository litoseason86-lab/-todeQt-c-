#ifndef BACKUPOPERATIONS_H
#define BACKUPOPERATIONS_H

#include "BackupOperationControl.h"

#include <QByteArray>
#include <QMap>
#include <QString>
#include <QVariantMap>

#include <memory>

class QSettings;

namespace BackupOperations {

// 外部备份包含本机历史、同步日志和索引，独立于同步快照预算；超限必须拒绝，不能截断。
inline constexpr qint64 kMaxBackupFileBytes = 512LL * 1024 * 1024;
inline constexpr qint64 kMaxBackupRows = 5'000'000;
inline constexpr qint64 kMaxBackupCellBytes = 16LL * 1024 * 1024;

// 每日目标历史每天最多一个键，约 365 个/年；40000 项可容纳约 100 年历史及几十项普通偏好。
inline constexpr int kMaxSettingEntries = 40000;
// 单值按序列化后的字节计量，沿用旧格式上限，避免外部长度字段引起过量分配。
inline constexpr int kMaxSettingValueBytes = 64 * 1024;
// 自有键的 UTF-8 字节与序列化值合计；限制外部文件解析内存，不作为业务输入限制。
inline constexpr qint64 kMaxSettingsTotalBytes = 8LL * 1024 * 1024;

// 平台字段只用于显示与排查；按运行时产品类型映射，避免服务层引入编译期平台分支。
// macOS 保持旧备份的显示值，其余未识别产品类型原样保留。
QString platformDisplayName(const QString& productType);

// 打开偏好存储：路径为空时是生产用的 macOS 原生偏好，否则是 ini 文件（测试用）。
// 原生偏好默认开启回退，allKeys() 会连系统全局域的键（文本替换词典、语言、地区……）
// 一起列出来；这里一律关掉回退，只看本应用自己的偏好域。
std::unique_ptr<QSettings> openSettings(const QString& settingsFilePath);

// 本机偏好快照要覆盖的键：本应用拥有的分组，加上只属于这台设备的自动备份策略（backup/）。
// 回滚和「保留本机备份策略」都只处理这些键，别的键既不读也不写。
bool isLocalSettingKey(const QString& key);

struct OperationResult
{
    bool success = false;
    QString error;
    // 原子提交已发生时保留事实；提交后取消不能让调用方误判为原目标未动。
    bool committed = false;
};

struct EmbeddedSettingsResult
{
    bool success = false;
    QString error;
    QVariantMap values;
};

// 请求只带已经序列化的应用偏好；执行器不接触主进程的偏好域。
using OwnedSettings = QMap<QString, QByteArray>;

// 捕获、协议及文件读取共用预算；只计本应用拥有的键，不截断或删除历史。
bool checkSettingsBudget(const OwnedSettings& values, QString* reason);

struct CapturedSettingsResult
{
    bool success = false;
    QString error;
    OwnedSettings values;
    QString effectiveSettingsPath;
};

struct SnapshotRequest
{
    QString sourceDatabasePath;
    QString destinationPath;
    QString stagingDirectory;
    QString effectiveSettingsPath;
    QString kind;
    int currentSchemaVersion = 0;
    OwnedSettings settings;
};

CapturedSettingsResult captureOwnedSettings(const QString& settingsFilePath,
                                            const BackupOperation& operation = {});
OperationResult createSnapshot(const SnapshotRequest& request,
                               const BackupOperation& operation = {});
OperationResult createSnapshot(const QString& sourceDatabasePath,
                               const QString& settingsFilePath,
                               const QString& destinationPath,
                               const QString& kind,
                               int currentSchemaVersion,
                               const BackupOperation& operation = {},
                               const QString& stagingDirectory = {});
QVariantMap inspectBackup(const QString& sourcePath, int currentSchemaVersion,
                          const BackupOperation& operation = {});
EmbeddedSettingsResult readEmbeddedSettings(const QString& sourcePath,
                                            const BackupOperation& operation = {});
// 外部暂存和发布备份必须传同源预算；本地可信回滚沿用负值，不因新支持上限丢失回滚能力。
OperationResult atomicCopy(const QString& sourcePath, const QString& destinationPath,
                           qint64 maxBytes = -1, const BackupOperation& operation = {});

} // namespace BackupOperations

#endif // BACKUPOPERATIONS_H
