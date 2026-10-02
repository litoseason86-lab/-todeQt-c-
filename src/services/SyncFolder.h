#ifndef SYNCFOLDER_H
#define SYNCFOLDER_H

#include <QByteArray>
#include <QString>
#include <QStringList>

// 同步文件夹的读写接口（050 阶段 3）。
// Mac 直接读写 iCloud 云盘里的目录；iPad 只能访问用户在「文件」里选中的文件夹，靠安全作用域书签
// （系统签发的一段授权数据，重开应用后凭它重新取得访问权）加文件协调读写。两边的实现放在各自的平台目录，
// 同步核心只认这个接口，不做平台判断。测试用本地临时目录（LocalSyncFolder）。
//
// 所有方法都在同步的工作线程里调用，可能阻塞：读一个刚从云端同步来、还没下载到本机的文件，049 实测约 1 秒。
// SyncEngine 把文件操作排成一队，同一时刻只有一个线程在用同一个对象，实现不必自己加锁。
// 路径一律相对同步文件夹的根，用「/」分隔。
class SyncFolder
{
public:
    enum class ErrorKind {
        None,
        // 文件或目录不存在。
        NotFound,
        // 整个文件夹用不了：没登录 Apple ID、关了 iCloud 云盘、书签失效、没有权限。同步暂停，等它恢复。
        Unavailable,
        // 本机磁盘空间不足。
        NoSpace,
        // 其它读写错误，下一轮再试。
        Io,
    };
    struct Error {
        ErrorKind kind = ErrorKind::None;
        QString message;
        bool ok() const { return kind == ErrorKind::None; }
    };

    virtual ~SyncFolder() = default;

    // 取得访问权。可以重复调用：每一轮同步开始时都调一次，文件夹暂时不可用之后恢复了也能接上。
    virtual bool open(Error* error) = 0;
    // 文件夹自己的名字（路径最后一段）。没有标记文件时，拿它推测用户选成了哪一层。
    virtual QString name() const = 0;
    // 给人看的位置。
    virtual QString displayPath() const = 0;

    // 列出目录里的名字，文件和子目录都在内，隐藏文件也在内。relativeDir 为空表示根。目录不存在时报 NotFound。
    virtual QStringList list(const QString& relativeDir, Error* error) = 0;
    virtual bool read(const QString& relativePath, QByteArray* data, Error* error) = 0;
    // 原子写入：先写临时文件，写完整再换上，对方永远读不到写了一半的文件。所在目录不存在时一并建出来。
    virtual bool write(const QString& relativePath, const QByteArray& data, Error* error) = 0;
    // 删除文件。本来就不存在也算成功。
    virtual bool remove(const QString& relativePath, Error* error) = 0;
    // 这个文件往 iCloud 上传时出的错（例如 iCloud 空间已满）。没有问题、查不到或者不在 iCloud 里时返回空。
    virtual QString uploadProblem(const QString& relativePath)
    {
        Q_UNUSED(relativePath);
        return {};
    }
    // 放弃正在等待的读写（iPad 的文件协调在下载不下来时可能一直等着）。可以从别的线程调用，退出时用。
    virtual void cancelPendingIo() {}
};

#endif // SYNCFOLDER_H
