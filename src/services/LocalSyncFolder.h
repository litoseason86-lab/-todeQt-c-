#ifndef LOCALSYNCFOLDER_H
#define LOCALSYNCFOLDER_H

#include "SyncFolder.h"

// 直接读写本机的一个目录。Mac 版的 iCloud 云盘目录就是本机目录（系统在后台上传、下载），
// 平台层在它外面补上「iCloud 可不可用」的判断；测试用它读写临时目录。
//
// 读、列目录用 POSIX 接口而不是 QFile/QDir：QDir 没有权限时只返回空列表，分不清「没有文件」和「被拒绝」，
// 而同步要靠这个区别决定是暂停还是继续（049 探针也是这么做的）。写入用 QSaveFile 做原子替换。
class LocalSyncFolder : public SyncFolder
{
public:
    // rootPath：同步文件夹的绝对路径。它本身可以还不存在（Mac 第一次开启同步），第一次写入时一并建出来；
    // 但它所在的上一级必须存在，否则当作整个位置不可用。
    explicit LocalSyncFolder(QString rootPath);

    bool open(Error* error) override;
    QString name() const override;
    QString displayPath() const override;
    QStringList list(const QString& relativeDir, Error* error) override;
    bool read(const QString& relativePath, QByteArray* data, Error* error) override;
    bool write(const QString& relativePath, const QByteArray& data, Error* error) override;
    bool remove(const QString& relativePath, Error* error) override;

protected:
    QString absolutePath(const QString& relativePath) const;
    const QString& rootPath() const { return m_root; }

private:
    QString m_root;
};

#endif // LOCALSYNCFOLDER_H
