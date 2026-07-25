#ifndef BACKUPOPERATIONS_H
#define BACKUPOPERATIONS_H

#include <QString>
#include <QVariantMap>

namespace BackupOperations {

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
