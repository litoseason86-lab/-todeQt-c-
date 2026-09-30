#ifndef IOSFOLDERPICKER_H
#define IOSFOLDERPICKER_H

#include <QByteArray>
#include <QString>

#include <functional>

// 弹出系统「文件」选择器，让你选 iCloud 云盘里的同步文件夹。回调给出这个文件夹的书签：
// IosSyncFolder 凭它在之后每次启动时重新取得访问权。取消或失败时书签为空，message 说明原因。
// 必须在界面线程调用，回调也在界面线程执行。选中的是不是同步文件夹，由同步引擎读标记文件判断。
void presentSyncFolderPicker(std::function<void(const QByteArray& bookmark, const QString& message)> done);

#endif // IOSFOLDERPICKER_H
