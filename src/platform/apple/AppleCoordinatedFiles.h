#ifndef APPLECOORDINATEDFILES_H
#define APPLECOORDINATEDFILES_H

#include "../../services/SyncFolder.h"

#include <memory>

// Apple 两端共用的文件协调：让 iCloud 等文件呈现者先准备好，再读、原子替换或删除文件。
// 头文件只用 C++/Qt 类型，隐藏 ObjC 对象和生命周期，让 MacSyncFolder.cpp 保持纯 C++。
class AppleCoordinatedFiles final
{
public:
    AppleCoordinatedFiles();
    ~AppleCoordinatedFiles();

    // absolutePath 是实际访问的绝对路径；relativePath 保留同步文件预算分类和原有错误文字。
    // 与 SyncFolder 一样，读写删串行运行于同一个工作线程，不并行使用同一个实例。
    bool read(const QString& absolutePath, const QString& relativePath,
              QByteArray* data, SyncFolder::Error* error);
    bool write(const QString& absolutePath, const QString& relativePath,
               const QByteArray& data, SyncFolder::Error* error);
    bool remove(const QString& absolutePath, const QString& relativePath, SyncFolder::Error* error);

    // 取消是唯一可跨线程调用的方法；它不等待协调线程，不改变之后新建协调者的状态。
    void cancelPendingIo();

private:
    struct State;
    std::unique_ptr<State> d;
};

#endif // APPLECOORDINATEDFILES_H
