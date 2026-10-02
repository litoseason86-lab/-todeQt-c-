#ifndef SYNCEDSETTINGS_H
#define SYNCEDSETTINGS_H

#include <QHash>
#include <QString>

// 跟着同步的设置在本机怎么读、怎么写回（计划 050 的逻辑日起点，加上 051 的 D1 选定的内容类设置）。
// 哪些键、给人看的名字在 SyncSchema；这里接到 AppSettings 和课表服务上。同步核心（SyncStore）只认文本，
// 不知道这些值存在哪里，读出与写回都经过这里。
//
// 值的文本格式：整数用十进制，开关用 1 / 0，学期起始日用 yyyy-MM-dd（未设置为空），
// 课表节次是按节次先后的 [[开始分钟, 结束分钟], …]。两台设备同样的值得到逐字相同的文本，比较才有意义。
namespace SyncedSettings {

// 本机现在的全部同步设置（键 → 值）：固定的几项，加上每一天的今日目标。
QHash<QString, QString> currentValues();
// 是不是出厂默认值。第一次记下时默认值用最小版本，另一台设备改过的会盖过它，而不是反过来。今日目标没有默认值。
bool isFactoryDefault(const QString& key, const QString& value);
// 把同步来的值写回本机。不认识的键、不合法的值（外部改坏的、更新版本的取值）不写，返回 false。
bool apply(const QString& key, const QString& value);
// 整体替换时快照里没有的项：今日目标从本机删掉（以快照为准）；固定的几项保留本机的值——
// 只有更早版本写的快照才会缺它们，下次启动时会把本机的值记进去。
bool remove(const QString& key);

// 同步正在把对方的值写回本机（提交后的写回、启动时的核对）。这期间各项设置发出的变更信号不是本机改动，
// 记录方（SyncController）要跳过：一批里有好几项时，先写回的那一项发出信号，记录方会看到「别的项还没写回、
// 和库里记的不一样」，把本机的旧值当成新改动、用新版本记下来，反把对方的改动盖掉。
// 只在主线程里用（设置与同步的写库都在主线程）。
class WriteBackScope
{
public:
    WriteBackScope();
    ~WriteBackScope();
    WriteBackScope(const WriteBackScope&) = delete;
    WriteBackScope& operator=(const WriteBackScope&) = delete;
};
bool isWritingBack();

} // namespace SyncedSettings

#endif // SYNCEDSETTINGS_H
