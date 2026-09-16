#ifndef BACKUPOPERATIONS_H
#define BACKUPOPERATIONS_H

#include <QString>
#include <QVariantMap>

#include <memory>

class QSettings;

namespace BackupOperations {

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
};

struct EmbeddedSettingsResult
{
    bool success = false;
    QString error;
    QVariantMap values;
};

OperationResult createSnapshot(const QString& sourceDatabasePath,
                               const QString& settingsFilePath,
                               const QString& destinationPath,
                               const QString& kind,
                               int currentSchemaVersion);
QVariantMap inspectBackup(const QString& sourcePath, int currentSchemaVersion);
EmbeddedSettingsResult readEmbeddedSettings(const QString& sourcePath);
OperationResult atomicCopy(const QString& sourcePath, const QString& destinationPath);

} // namespace BackupOperations

#endif // BACKUPOPERATIONS_H
