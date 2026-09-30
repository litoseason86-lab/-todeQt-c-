#include "MacSyncFolder.h"

#include "../../services/SyncFiles.h"
#include "../apple/AppleUbiquitousItem.h"

#include <QDir>
#include <QFileInfo>

MacSyncFolder::MacSyncFolder(const QString& iCloudDriveRoot)
    : LocalSyncFolder(iCloudDriveRoot + QLatin1Char('/') + SyncFiles::defaultFolderName())
    , m_iCloudDriveRoot(iCloudDriveRoot)
{
}

QString MacSyncFolder::defaultICloudDriveRoot()
{
    return QDir::homePath() + QStringLiteral("/Library/Mobile Documents/com~apple~CloudDocs");
}

bool MacSyncFolder::open(Error* error)
{
    // 退出 Apple ID 或关掉 iCloud 云盘之后，这个目录会被系统移走。此时不能在原处自己建一个出来：
    // 建出来的只是本机的普通文件夹，写进去的东西永远到不了 iPad，还会让人以为同步正常。
    if (!QFileInfo(m_iCloudDriveRoot).isDir()) {
        if (error) {
            *error = {ErrorKind::Unavailable,
                      QStringLiteral("找不到 iCloud 云盘（%1）：没有登录 Apple ID，或者没有打开 iCloud 云盘")
                          .arg(QDir::toNativeSeparators(m_iCloudDriveRoot))};
        }
        return false;
    }
    return LocalSyncFolder::open(error);
}

QString MacSyncFolder::uploadProblem(const QString& relativePath)
{
    return AppleUbiquitousItem::uploadProblem(absolutePath(relativePath));
}
