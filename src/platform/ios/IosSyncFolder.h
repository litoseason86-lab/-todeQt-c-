#ifndef IOSSYNCFOLDER_H
#define IOSSYNCFOLDER_H

#include "../../services/SyncFolder.h"

#include <QByteArray>

#include <functional>
#include <memory>

// iPad 上的同步文件夹：你在「文件」选择器里选中的那个 iCloud 云盘文件夹。
// iOS 应用在沙盒里，只能访问选中的文件夹。系统给的访问权只在 start/stopAccessingSecurityScopedResource 之间有效；
// 重开应用后靠书签（选中时系统签发的一段授权数据）重新取得。049 实测重开、重装后书签都能直接用。
// 读写都经过 NSFileCoordinator（文件协调）：云盘里的文件可能还没下载，协调读取会让系统先下载好；
// 也避免和系统的同步进程同时改同一个文件。
// 头文件保持纯 C++，装配代码可以直接包含；ObjC 细节在 .mm 里。
class IosSyncFolder final : public SyncFolder
{
public:
    // bookmarkRefreshed：书签被系统标为过期时，这里会重新生成一份，交给调用方存起来替换旧的
    // （在工作线程里调用）。不替换的话，下次启动可能就解析不出来了。
    IosSyncFolder(QByteArray bookmark, std::function<void(const QByteArray&)> bookmarkRefreshed);
    ~IosSyncFolder() override;

    bool open(Error* error) override;
    QString name() const override;
    QString displayPath() const override;
    QStringList list(const QString& relativeDir, Error* error) override;
    bool read(const QString& relativePath, QByteArray* data, Error* error) override;
    bool write(const QString& relativePath, const QByteArray& data, Error* error) override;
    bool remove(const QString& relativePath, Error* error) override;
    QString uploadProblem(const QString& relativePath) override;
    void cancelPendingIo() override;

private:
    struct State;
    std::unique_ptr<State> d;
};

#endif // IOSSYNCFOLDER_H
