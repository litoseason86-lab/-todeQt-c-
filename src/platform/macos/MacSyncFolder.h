#ifndef MACSYNCFOLDER_H
#define MACSYNCFOLDER_H

#include "../../services/LocalSyncFolder.h"

// Mac 上的同步文件夹：iCloud 云盘里的「番茄Todo同步」。Mac 版没有沙盒，直接读写这个目录，
// 系统在后台上传、下载；049 实测不弹授权框，重建应用之后也不弹。
// 读一个刚从 iPad 同步来的文件时，开着「优化 Mac 存储」的话系统要先下载，约 1 秒，所以只在工作线程里用。
class MacSyncFolder : public LocalSyncFolder
{
public:
    // iCloudDriveRoot：iCloud 云盘在本机的目录。测试换成临时目录，就不碰真实的 iCloud 云盘。
    explicit MacSyncFolder(const QString& iCloudDriveRoot = defaultICloudDriveRoot());

    // ~/Library/Mobile Documents/com~apple~CloudDocs
    static QString defaultICloudDriveRoot();

    // iCloud 云盘目录不存在（没登录 Apple ID、没打开 iCloud 云盘）时报「不可用」，并说清楚是什么原因。
    bool open(Error* error) override;
    QString uploadProblem(const QString& relativePath) override;

private:
    QString m_iCloudDriveRoot;
};

#endif // MACSYNCFOLDER_H
